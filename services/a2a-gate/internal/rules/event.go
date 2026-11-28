package rules

import (
	"fmt"
	"regexp"
	"strings"
)

// EventRate is a token bucket per caller and per gate replica.
type EventRate struct {
	PerMinute int `json:"perMinute"` // 1 to 600
	Burst     int `json:"burst"`     // 1 to 60
}

// Event is the optional `event` block of a caller (ADR 0027). Every field is required, so a misspelt field fails at
// start instead of falling back to a wider default.
type Event struct {
	Text        string    `json:"text"` // the pattern the whole message text must match (grammar: CompileEventText)
	Rate        EventRate `json:"rate"`
	MaxInFlight int       `json:"maxInFlight"` // open calls of this caller at the gate, 1 to 32

	re *regexp.Regexp
}

// Match reports whether the whole text matches the event pattern. A text that is not printable ASCII, or is longer
// than MaxEventTextBytes, never matches.
func (e *Event) Match(text string) bool {
	if e == nil || e.re == nil || len(text) > MaxEventTextBytes {
		return false
	}
	for i := 0; i < len(text); i++ {
		if text[i] > 0x7e || text[i] < 0x20 {
			return false
		}
	}
	return e.re.MatchString(text)
}

// checkEvent validates the event block of one caller and compiles its pattern.
func (c *Caller) checkEvent() error {
	e := c.Event
	if e == nil {
		return nil
	}
	switch {
	case c.Key || c.ServiceAccount == nil:
		return fmt.Errorf("caller %q: an event caller authenticates with a ServiceAccount, not a key", c.Name)
	case c.Methods != nil:
		return fmt.Errorf("caller %q: an event caller has no methods (it sends SendMessage only)", c.Name)
	case c.Memory:
		return fmt.Errorf("caller %q: an event caller may not use the memory service", c.Name)
	case c.UserID.Fixed == "" || c.UserID.Exact != "" || c.UserID.Prefix != "":
		return fmt.Errorf("caller %q: an event caller's userId must be fixed", c.Name)
	case e.Rate.PerMinute < 1 || e.Rate.PerMinute > 600:
		return fmt.Errorf("caller %q: event.rate.perMinute must be 1 to 600", c.Name)
	case e.Rate.Burst < 1 || e.Rate.Burst > 60:
		return fmt.Errorf("caller %q: event.rate.burst must be 1 to 60", c.Name)
	case e.MaxInFlight < 1 || e.MaxInFlight > 32:
		return fmt.Errorf("caller %q: event.maxInFlight must be 1 to 32", c.Name)
	}
	re, err := CompileEventText(e.Text)
	if err != nil {
		return fmt.Errorf("caller %q: event.text: %w", c.Name, err)
	}
	e.re = re
	return nil
}

// checkEventCallers enforces what spans callers: at most MaxEventCallers event callers, and an event caller's fixed
// user id belongs to it alone (no other rule may equal it, and no prefix may cover it), so no other caller can take
// an event's message id under the same user id.
func (r *Rules) checkEventCallers() error {
	n := 0
	for i := range r.Callers {
		ev := &r.Callers[i]
		if ev.Event == nil {
			continue
		}
		if n++; n > MaxEventCallers {
			return fmt.Errorf("at most %d callers may have an event block", MaxEventCallers)
		}
		id := ev.UserID.Fixed
		for j := range r.Callers {
			if j == i {
				continue
			}
			o := r.Callers[j].UserID
			if o.Exact == id || o.Fixed == id || (o.Prefix != "" && strings.HasPrefix(id, o.Prefix)) {
				return fmt.Errorf("caller %q: its user id rule covers the user id of the event caller %q, which belongs to that caller alone", r.Callers[j].Name, ev.Name)
			}
		}
	}
	return nil
}
