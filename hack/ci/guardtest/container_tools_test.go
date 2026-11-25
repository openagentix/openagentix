package guardtest

import (
	"testing"
)

// Tools for container agents (ADR 0019): the guard with controlPlane.containerAgents.toolProfiles={lookup}. The allowed objects are the
// adapter's golden output for an agent on the profile lookup (services/control-plane/testdata/container-objects-tools.json); every denied
// case changes ONE thing in them.

const (
	tokDir   = "/var/run/secrets/openagentix/mcp"
	toolURL  = "http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp"
	toolAud  = "openagentix-vmcp-lookup-workload"
	objsTool = "services/control-plane/testdata/container-objects-tools.json"
)

var toolSets = append([]string{"controlPlane.containerAgents.toolProfiles={lookup}"}, containerSets...)

// tokenVol is the projected volume of the pod, as the API server stores it (defaultMode added).
func tokenVol(pod m) m { return pod["volumes"].([]any)[1].(m) }
func tokenSrc(pod m) m {
	return tokenVol(pod)["projected"].(m)["sources"].([]any)[0].(m)["serviceAccountToken"].(m)
}

func TestContainerGuardWithAToolProfile(t *testing.T) {
	r := render(t, toolSets...)
	e, err := newEngine(r.Policies)
	if err != nil {
		t.Fatal(err)
	}
	objs := containerObjectsFrom(t, r, objsTool)
	plain := containerObjects(t, r)
	var cases []expectation
	for _, k := range []string{"Deployment", "NetworkPolicy"} {
		o := objs[k]
		cases = append(cases,
			wl("allow "+k+" with a tool profile CREATE", k, "CREATE", deepCopy(o), nil, allow),
			wl("allow "+k+" with a tool profile UPDATE with what the server adds", k, "UPDATE", server2(o), server2(o), allow),
			wl("allow "+k+" with a tool profile DELETE", k, "DELETE", nil, server2(o), allow),
			// an agent without a profile is still allowed when profiles are open
			wl("allow "+k+" without a tool profile CREATE", k, "CREATE", deepCopy(plain[k]), nil, allow),
			wl("allow "+k+" without a tool profile UPDATE", k, "UPDATE", server2(plain[k]), server2(plain[k]), allow))
	}
	dep := func(name string, f func(spec, pod, c m)) expectation {
		return mut(name, "Deployment", objs, func(x m) {
			spec := x["spec"].(m)
			pod := spec["template"].(m)["spec"].(m)
			f(spec, pod, pod["containers"].([]any)[0].(m))
		})
	}
	label := func(s m) m { return s["template"].(m)["metadata"].(m)["labels"].(m) }
	cases = append(cases,
		// the pod label: only a listed profile, only next to the agent label
		dep("deny a profile label that is not listed", func(s, p, c m) { label(s)["openagentix.io/tool-profile"] = "other" }),
		dep("deny a profile label with an extra label", func(s, p, c m) { label(s)["extra"] = "x" }),
		dep("deny the tool pieces without the profile label", func(s, p, c m) { delete(label(s), "openagentix.io/tool-profile") }),
		// the token: one source, the profile's audience, path token, at most an hour
		dep("deny a token for another audience", func(s, p, c m) { tokenSrc(p)["audience"] = "openagentix-vmcp-lookup" }),
		dep("deny a token for the A2A gate's audience", func(s, p, c m) { tokenSrc(p)["audience"] = "openagentix-a2a" }),
		dep("deny a token for the Kubernetes API", func(s, p, c m) { delete(tokenSrc(p), "audience") }),
		dep("deny a token that lives a day", func(s, p, c m) { tokenSrc(p)["expirationSeconds"] = int64(86400) }),
		dep("deny a token without an expiry", func(s, p, c m) { delete(tokenSrc(p), "expirationSeconds") }),
		dep("deny a token at another path", func(s, p, c m) { tokenSrc(p)["path"] = "../../token" }),
		dep("deny a token with an extra field", func(s, p, c m) { tokenSrc(p)["extra"] = "x" }),
		dep("deny a second projected source: a Secret", func(s, p, c m) {
			src := tokenVol(p)["projected"].(m)
			src["sources"] = append(src["sources"].([]any), m{"secret": m{"name": "kagent-db-credentials"}})
		}),
		dep("deny a projected ConfigMap instead of the token", func(s, p, c m) {
			tokenVol(p)["projected"].(m)["sources"] = []any{m{"configMap": m{"name": "x"}}}
		}),
		dep("deny a projected downward API instead of the token", func(s, p, c m) {
			tokenVol(p)["projected"].(m)["sources"] = []any{m{"downwardAPI": m{"items": []any{m{"path": "x", "fieldRef": m{"fieldPath": "metadata.name"}}}}}}
		}),
		dep("deny another projected mode", func(s, p, c m) { tokenVol(p)["projected"].(m)["defaultMode"] = int64(511) }),
		dep("deny the token volume under another name", func(s, p, c m) { tokenVol(p)["name"] = "other" }),
		dep("deny a secret volume in place of the token", func(s, p, c m) { p["volumes"].([]any)[1] = m{"name": "mcp-token", "secret": m{"secretName": "x"}} }),
		dep("deny a third volume", func(s, p, c m) { p["volumes"] = append(p["volumes"].([]any), m{"name": "x", "emptyDir": m{}}) }),
		// the mount
		dep("deny a writable token mount", func(s, p, c m) { c["volumeMounts"].([]any)[1].(m)["readOnly"] = false }),
		dep("deny the token mounted somewhere else", func(s, p, c m) { c["volumeMounts"].([]any)[1].(m)["mountPath"] = "/etc" }),
		dep("deny the token mounted with a subPath", func(s, p, c m) { c["volumeMounts"].([]any)[1].(m)["subPath"] = "token" }),
		// the env
		dep("deny another tool URL", func(s, p, c m) {
			setEnv(c, "OPENAGENTIX_MCP_URL", "http://vmcp-tools.mcp-tools.svc.cluster.local:4483/mcp")
		}),
		dep("deny another token file", func(s, p, c m) { setEnv(c, "OPENAGENTIX_MCP_TOKEN_FILE", "/tmp/token") }),
		dep("deny the tool URL from a field", func(s, p, c m) {
			for _, x := range c["env"].([]any) {
				if x.(m)["name"] == "OPENAGENTIX_MCP_URL" {
					delete(x.(m), "value")
					x.(m)["valueFrom"] = m{"fieldRef": m{"fieldPath": "metadata.name"}}
				}
			}
		}),
		dep("deny the service account token mounted after all", func(s, p, c m) { p["automountServiceAccountToken"] = true }),
	)
	// without the label nothing of the tool pieces is allowed
	noLabel := func(name string, f func(spec, pod, c m)) expectation {
		return mut(name, "Deployment", plain, func(x m) {
			spec := x["spec"].(m)
			pod := spec["template"].(m)["spec"].(m)
			f(spec, pod, pod["containers"].([]any)[0].(m))
		})
	}
	tp := objs["Deployment"]["spec"].(m)["template"].(m)["spec"].(m)
	cases = append(cases,
		noLabel("deny the tool URL without the profile label", func(s, p, c m) {
			c["env"] = append(c["env"].([]any), m{"name": "OPENAGENTIX_MCP_URL", "value": toolURL})
		}),
		noLabel("deny the token file without the profile label", func(s, p, c m) {
			c["env"] = append(c["env"].([]any), m{"name": "OPENAGENTIX_MCP_TOKEN_FILE", "value": tokDir + "/token"})
		}),
		noLabel("deny the token volume without the profile label", func(s, p, c m) {
			p["volumes"] = append(p["volumes"].([]any), deepCopy(tp["volumes"].([]any)[1].(m)))
		}),
	)
	np := func(name string, f func(spec m)) expectation {
		return mut(name, "NetworkPolicy", objs, func(x m) { f(x["spec"].(m)) })
	}
	third := func(s m) m { return s["egress"].([]any)[2].(m) }
	cases = append(cases,
		np("deny egress to the profile's server for Substrate agents", func(s m) {
			third(s)["to"].([]any)[0].(m)["podSelector"].(m)["matchLabels"].(m)["toolhive-name"] = "tools-lookup"
		}),
		np("deny egress to the shared tool server", func(s m) {
			third(s)["to"].([]any)[0].(m)["podSelector"].(m)["matchLabels"].(m)["toolhive-name"] = "tools"
		}),
		np("deny egress to every pod of the tools namespace", func(s m) { delete(third(s)["to"].([]any)[0].(m), "podSelector") }),
		np("deny egress to the server in another namespace", func(s m) {
			third(s)["to"].([]any)[0].(m)["namespaceSelector"] = m{"matchLabels": m{"kubernetes.io/metadata.name": "kagent"}}
		}),
		np("deny egress to the server on another port", func(s m) { third(s)["ports"].([]any)[0].(m)["port"] = int64(9464) }),
		np("deny egress to the server on every port", func(s m) { delete(third(s), "ports") }),
		np("deny a fourth egress rule", func(s m) { s["egress"] = append(s["egress"].([]any), deepCopy(third(s))) }),
		np("deny the third rule to the internet", func(s m) { s["egress"].([]any)[2] = m{"to": []any{m{"ipBlock": m{"cidr": "0.0.0.0/0"}}}} }),
	)
	allowedN, deniedN := runCases(t, e, cases)
	t.Logf("container guard with a tool profile: %d cases (%d allowed, %d refused)", len(cases), allowedN, deniedN)
	if deniedN < 30 {
		t.Errorf("the suite shrank: %d refused cases", deniedN)
	}
}

// With no profile opened (the default), the objects of an agent with a profile are refused: the label, the token and the third egress rule.
func TestContainerGuardWithoutOpenProfilesRefusesToolPieces(t *testing.T) {
	r := render(t, containerSets...)
	e, err := newEngine(r.Policies)
	if err != nil {
		t.Fatal(err)
	}
	objs := containerObjectsFrom(t, r, objsTool)
	var cases []expectation
	for _, k := range []string{"Deployment", "NetworkPolicy"} {
		cases = append(cases, wl("deny "+k+" with a tool profile when no profile is open", k, "CREATE", deepCopy(objs[k]), nil, deny))
	}
	runCases(t, e, cases)
}
