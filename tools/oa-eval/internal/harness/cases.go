package harness

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

var reID = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// LoadCases reads and validates an evaluation set. An unknown key is an error: a misspelled check must not be
// silently skipped, because a check that is not run looks like a check that passed.
func LoadCases(path string) (*CaseSet, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	dec := yaml.NewDecoder(bytes.NewReader(b))
	dec.KnownFields(true)
	var cs CaseSet
	if err := dec.Decode(&cs); err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := cs.validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &cs, nil
}

func (cs *CaseSet) validate() error {
	if cs.Version == 0 {
		cs.Version = 1
	}
	if cs.Version != 1 {
		return fmt.Errorf("version %d is not supported (this tool reads version 1)", cs.Version)
	}
	if len(cs.Cases) == 0 {
		return errors.New("the set has no cases")
	}
	seen := map[string]bool{}
	for i := range cs.Cases {
		c := &cs.Cases[i]
		if err := c.validate(); err != nil {
			return fmt.Errorf("case %d (%q): %w", i+1, c.ID, err)
		}
		if seen[c.ID] {
			return fmt.Errorf("case id %q is used twice", c.ID)
		}
		seen[c.ID] = true
	}
	return nil
}

func (c *Case) validate() error {
	if !reID.MatchString(c.ID) {
		return errors.New("id is required and may hold only letters, digits, dot, dash and underscore")
	}
	switch {
	case c.Input == "" && len(c.Event) == 0:
		return errors.New("give an input (a prompt) or an event")
	case c.Input != "" && len(c.Event) > 0:
		return errors.New("give an input or an event, not both")
	}
	if m := c.Expect.MaxToolCalls; m != nil && *m < 1 {
		return fmt.Errorf("max_tool_calls is %d: it must be at least 1 (leave it out for no limit)", *m)
	}
	for _, list := range [][]string{c.Expect.AnswerMust, c.Expect.AnswerMustNot} {
		for _, expr := range list {
			if _, err := regexp.Compile(expr); err != nil {
				return fmt.Errorf("bad regular expression %q: %w", expr, err)
			}
		}
	}
	for i, s := range c.Expect.StateChecks {
		if !strings.HasPrefix(s.URL, "/") {
			return fmt.Errorf("state_checks[%d]: url must start with / and is read under the state base", i)
		}
		n := 0
		if s.Equals != nil {
			n++
		}
		if s.Matches != "" {
			n++
			if _, err := regexp.Compile(s.Matches); err != nil {
				return fmt.Errorf("state_checks[%d]: bad regular expression: %w", i, err)
			}
		}
		if s.Count != nil {
			n++
		}
		if s.Exists != nil {
			n++
		}
		if n != 1 {
			return fmt.Errorf("state_checks[%d]: give exactly one of equals, matches, count, exists", i)
		}
	}
	if c.Outcome != nil {
		for _, l := range c.Outcome.Labels {
			if l.Label == "" {
				return errors.New("outcome: a label rule needs a label")
			}
			if _, err := regexp.Compile(l.Match); err != nil {
				return fmt.Errorf("outcome: bad regular expression: %w", err)
			}
		}
	}
	return nil
}
