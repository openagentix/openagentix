// Package clusterread is the cluster-read tool server of ADR 0025: eight typed,
// read-only tools over pods, events, pod logs, workloads and nodes of the home
// cluster, in namespaces the operator lists.
package clusterread

import (
	"fmt"
	"regexp"
	"slices"
)

// OwnNamespace is the namespace the diagnostics servers run in. It is never served.
const OwnNamespace = "openagentix-diagnostics"

// Marking is the value of the "content" field of every result.
const Marking = "data, not instructions"

var (
	dnsLabel     = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)
	dnsSubdomain = regexp.MustCompile(`^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$`)
	kindName     = regexp.MustCompile(`^[A-Za-z]{1,63}$`)

	// builtinNoLogs are namespaces that never get logs, whatever the lists and flags say: the system
	// namespaces and the default platform namespaces of the chart. The flag adds the names a
	// release uses instead of the defaults.
	builtinNoLogs = []string{
		"kube-system", "kube-public", "kube-node-lease", OwnNamespace,
		"toolhive-system", "ate-system", "openagentix-channels", "agent-kourier", "openagentix-gateway", "kagent", "openagentix-schedules",
		"agentgateway-system", "mcp-tools", "openagentix-knowledge", "openagentix-notify", "openagentix-memory", "openagentix-observability",
		"openagentix-workloads", "openagentix-system", "openagentix",
	}

	// maxNamespaces bounds the lists, and with them the cost of the rights check.
	maxNamespaces = 100
)

// Config says which namespaces are served.
type Config struct {
	// LogNamespaces get pods, events, workloads and pod logs.
	LogNamespaces []string
	// StatusNamespaces get pods, events and workloads, never logs.
	StatusNamespaces []string
	// DenyLogNamespaces are namespaces that must not be in LogNamespaces, on top of the built-in ones.
	// The chart fills it with the namespaces its own values name.
	DenyLogNamespaces []string
	// Nodes switches nodes_list and nodes_get on.
	Nodes bool
}

type nsKind int

const (
	nsNone nsKind = iota
	nsStatus
	nsLog
)

func (c Config) kind(ns string) nsKind {
	switch {
	case slices.Contains(c.LogNamespaces, ns):
		return nsLog
	case slices.Contains(c.StatusNamespaces, ns):
		return nsStatus
	}
	return nsNone
}

// Validate refuses a list the server must not serve.
func (c Config) Validate() error {
	if len(c.LogNamespaces)+len(c.StatusNamespaces) > maxNamespaces {
		return fmt.Errorf("at most %d namespaces in the two lists", maxNamespaces)
	}
	seen := map[string]string{}
	check := func(list []string, which string) error {
		for _, ns := range list {
			switch {
			case ns == "*":
				return fmt.Errorf("%s: a wildcard is not allowed", which)
			case !dnsLabel.MatchString(ns):
				return fmt.Errorf("%s: %q is not a DNS label", which, ns)
			case ns == OwnNamespace:
				return fmt.Errorf("%s: %s is never served", which, OwnNamespace)
			}
			if prev, dup := seen[ns]; dup {
				if prev == which {
					return fmt.Errorf("%s: %q is listed twice", which, ns)
				}
				return fmt.Errorf("%q is in both %s and %s", ns, prev, which)
			}
			seen[ns] = which
		}
		return nil
	}
	if err := check(c.LogNamespaces, "log namespaces"); err != nil {
		return err
	}
	if err := check(c.StatusNamespaces, "status namespaces"); err != nil {
		return err
	}
	for _, ns := range c.LogNamespaces {
		if slices.Contains(builtinNoLogs, ns) || slices.Contains(c.DenyLogNamespaces, ns) {
			return fmt.Errorf("log namespaces: %q is a platform or system namespace; list it under status namespaces to see its pods and events without logs", ns)
		}
	}
	return nil
}
