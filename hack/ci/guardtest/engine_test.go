package guardtest

// The engine runs the rendered ValidatingAdmissionPolicy objects through the Kubernetes admission CEL machinery
// (k8s.io/apiserver, the code the API server itself uses), so a rule is judged by evaluating it, never by matching its text.

import (
	"context"
	"fmt"
	"strings"

	v1 "k8s.io/api/admissionregistration/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apiserver/pkg/admission"
	"k8s.io/apiserver/pkg/admission/plugin/cel"
	"k8s.io/apiserver/pkg/admission/plugin/policy/validating"
	"k8s.io/apiserver/pkg/admission/plugin/webhook/matchconditions"
	celconfig "k8s.io/apiserver/pkg/apis/cel"
	"k8s.io/apiserver/pkg/authentication/user"
	"k8s.io/apiserver/pkg/cel/environment"
)

// request is one write the controller (or someone else) attempts.
type request struct {
	Name      string
	User      string
	Op        string // CREATE, UPDATE, DELETE
	Group     string
	Resource  string
	Sub       string // subresource, "" for the main resource
	Namespace string
	ObjName   string
	Object    map[string]any
	Old       map[string]any
}

type verdict struct {
	Allowed bool
	Matched []string // names of the policies that matched the request
	Why     []string // the messages of the validations that denied it
	// Rule: some validation said no by its own verdict, not only by failing to evaluate (an evaluation error also refuses the write, since
	// the policies fail closed, but a case that is refused ONLY by an error would not prove the rule that was meant to refuse it).
	Rule bool
}

type compiled struct {
	pol       v1.ValidatingAdmissionPolicy
	validator validating.Validator
}

type engine struct{ policies []compiled }

func newEngine(pols []v1.ValidatingAdmissionPolicy) (*engine, error) {
	env := environment.MustBaseEnvSet(environment.DefaultCompatibilityVersion())
	opt := cel.OptionalVariableDeclarations{HasAuthorizer: true}
	optNoAuth := cel.OptionalVariableDeclarations{}
	e := &engine{}
	for _, pol := range pols {
		fc, err := cel.NewCompositedCompiler(env)
		if err != nil {
			return nil, err
		}
		var vars []cel.NamedExpressionAccessor
		for _, v := range pol.Spec.Variables {
			vars = append(vars, &validating.Variable{Name: v.Name, Expression: v.Expression})
		}
		fc.CompileAndStoreVariables(vars, opt, environment.StoredExpressions)
		var mc []cel.ExpressionAccessor
		for i := range pol.Spec.MatchConditions {
			mc = append(mc, (*matchconditions.MatchCondition)(&pol.Spec.MatchConditions[i]))
		}
		matcher := matchconditions.NewMatcher(fc.CompileCondition(mc, opt, environment.StoredExpressions), pol.Spec.FailurePolicy, "policy", "validate", pol.Name)
		var vals, msgs []cel.ExpressionAccessor
		for _, v := range pol.Spec.Validations {
			vals = append(vals, &validating.ValidationCondition{Expression: v.Expression, Message: v.Message, Reason: v.Reason})
			msgs = append(msgs, &validating.MessageExpressionCondition{MessageExpression: v.MessageExpression})
		}
		val := validating.NewValidator(fc.CompileCondition(vals, opt, environment.StoredExpressions), matcher,
			fc.CompileCondition(nil, opt, environment.StoredExpressions), fc.CompileCondition(msgs, optNoAuth, environment.StoredExpressions), pol.Spec.FailurePolicy, nil)
		e.policies = append(e.policies, compiled{pol: pol, validator: val})
	}
	return e, nil
}

// ruleMatches reports whether one rule of matchConstraints selects the request (apiGroups, operations, resources, with the
// "*" and "*/*" wildcards and "plural/sub" entries).
func ruleMatches(r v1.NamedRuleWithOperations, group, resource, sub, op string) bool {
	in := func(list []string, v string) bool {
		for _, x := range list {
			if x == "*" || x == v {
				return true
			}
		}
		return false
	}
	if !in(r.APIGroups, group) {
		return false
	}
	ops := make([]string, 0, len(r.Operations))
	for _, o := range r.Operations {
		ops = append(ops, string(o))
	}
	if !in(ops, op) {
		return false
	}
	for _, x := range r.Resources {
		switch {
		case x == "*/*":
			return true
		case x == "*":
			if sub == "" {
				return true
			}
		case sub == "" && x == resource:
			return true
		case sub != "" && x == resource+"/"+sub:
			return true
		case sub != "" && x == "*/"+sub:
			return true
		case sub == "" && x == resource+"/*":
			// "plural/*" matches subresources only
		case sub != "" && x == resource+"/*":
			return true
		}
	}
	return false
}

func (p compiled) matches(r request) bool {
	mc := p.pol.Spec.MatchConstraints
	if mc == nil {
		return false
	}
	hit := false
	for _, rr := range mc.ResourceRules {
		if ruleMatches(rr, r.Group, r.Resource, r.Sub, r.Op) {
			hit = true
			break
		}
	}
	if !hit {
		return false
	}
	for _, rr := range mc.ExcludeResourceRules {
		if ruleMatches(rr, r.Group, r.Resource, r.Sub, r.Op) {
			return false
		}
	}
	return true
}

func (e *engine) eval(r request) verdict {
	gvr := schema.GroupVersionResource{Group: r.Group, Version: "v1", Resource: r.Resource}
	gvk := schema.GroupVersionKind{Group: r.Group, Version: "v1", Kind: "X"}
	var obj, old runtime.Object
	if r.Object != nil {
		obj = &unstructured.Unstructured{Object: deepCopy(r.Object)}
	}
	if r.Old != nil {
		old = &unstructured.Unstructured{Object: deepCopy(r.Old)}
	}
	v := verdict{Allowed: true}
	for _, p := range e.policies {
		if !p.matches(r) {
			continue
		}
		attrs := admission.NewAttributesRecord(obj, old, gvk, r.Namespace, r.ObjName, gvr, r.Sub, admission.Operation(r.Op), &metav1.CreateOptions{}, false, &user.DefaultInfo{Name: r.User})
		va := &admission.VersionedAttributes{Attributes: attrs, VersionedKind: gvk, VersionedObject: admission.NewLazyObject(obj), VersionedOldObject: admission.NewLazyObject(old)}
		res := p.validator.Validate(context.Background(), gvr, va, nil, nil, celconfig.RuntimeCELCostBudget, nil)
		if len(res.Decisions) == 0 {
			continue // the policy's matchConditions did not select the user
		}
		v.Matched = append(v.Matched, p.pol.Name)
		for _, d := range res.Decisions {
			if d.Action != validating.ActionAdmit {
				v.Allowed = false
				if d.Evaluation == validating.EvalDeny {
					v.Rule = true
				}
				msg := d.Message
				if i := strings.IndexByte(msg, '\n'); i > 0 {
					msg = msg[:i]
				}
				v.Why = append(v.Why, fmt.Sprintf("%s [%s] %.90s", p.pol.Name, d.Evaluation, msg))
			}
		}
	}
	return v
}
