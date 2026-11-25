# API conventions

The rules every OpenAgentix resource follows (ADR 0012, changes 5 to 13). They exist so that a product built on OpenAgentix, in its own
repository and its own API group, can depend on a resource without being broken by the next release. `AgentDefinition` is the first kind;
`services/control-plane/README.md` shows the rules applied to it.

## One group, a version per kind

- Every platform kind is in the group `openagentix.io`. Splitting a group later is a migration, so there is one.
- Each kind has its own version (`v1alpha1`, `v1beta1`, `v1`) and moves through them on its own. A product uses its own group and never puts
  its kinds in `openagentix.io`. No platform kind names a product concept: a repository, a work item, a pipeline or a release is the product's.
- **Before the first release that contains a kind**, its schema may change in place (nothing depends on it). That is how `AgentDefinition` got
  the shapes of ADR 0012 without a new version.
- **After it**, the Kubernetes deprecation rules apply: an alpha version may change or go without notice (a note in the changelog); a beta
  version is served for at least three platform releases after it is deprecated; a stable version is not removed within a major release. A change
  of a field's type, name or meaning, and the removal of a field a product may read, needs a new version and a conversion. Adding an optional
  field is always allowed.

## Spec: platform words only

- A spec names no upstream product (no runtime, gateway or tool-server name, no image, no namespace of a platform component). What an upstream
  needs is derived by its adapter from the platform's own terms, or comes from the catalog's adapter-owned section (`runtime.<adapter>`,
  `tools.<adapter>`). A test keeps these words out of the platform packages.
  One narrow exception, decided in [ADR 0015](decisions/0015-bring-your-own-agent.md): `spec.runtime.container.image`, the user's own agent image. It
  must be pinned by digest and must match an operator allowlist. No other image field exists anywhere in a spec. The rule above is otherwise unchanged.
- Identifiers the platform makes (a gateway user, a key Secret's name) are **opaque**: documented as strings, never to be parsed. Today a
  definition's gateway user is `<namespace>.<name>`.
- A field that is planned but not built is **reserved**: the schema allows it, its shape is fixed, and the controller refuses a value with the
  words "not available yet" instead of ignoring it (`instructionsFrom`, `knowledge.collections`, `notify.destinations`).
- Lists and objects that may grow are objects, not booleans (`knowledge: {enabled, collections}`), and a list of names is a list of objects
  when a version may follow (`skills: [{name, version}]`).

## Status: a contract and a private block

- **Public fields** are the contract and follow the deprecation rules above: `conditions`, `observedGeneration`, and the kind's own facts
  (for `AgentDefinition`: `endpoint`, `revision`, `effectiveTools`, `effectiveEgress`, `violations`, `capabilities`, `agentRef`).
- **Everything the controller keeps for itself** is under `status.controller` and may change without notice. Nothing outside the controller
  may read it.
- **Conditions.** Each kind documents the promise of its `Ready` condition and lists every reason, per condition, in one table. The other
  conditions are informational. For `AgentDefinition`: `Ready=True` means callable at `status.endpoint`, at `status.revision`.
- `revision` is a stable hash of what was applied, so that a run or a cost record can name the exact agent that did the work.
- A fact the platform could not verify is the explicit value `unknown`, never a guess (`status.capabilities`).

## Stop, not pause

`spec.suspend` is a **stop**. Where a runtime has no pause (kagent has none), suspending removes the runtime agent, so running conversations
end, and cuts the agent's model access (its key stops working at the gateway until resume); resuming is a fresh start with the same
definition, key and revision, and is rate-limited per definition so that a suspend and resume loop cannot thrash the runtime. A kind that
offers `suspend` documents this in its README; a product must not promise a paused conversation. Status says it with `Ready=False`, reason
`Suspended` (or `ResumeDelayed` while a resume waits).

## Reserved label keys

`openagentix.io/team`, `openagentix.io/project` and `openagentix.io/work-item` are reserved for products and for cost and trace attribution.
They are informational: anyone who can write the object can set them, so they never decide access, policy or billing on their own. The
controller copies `team` and `project` onto the objects it creates and into the gateway key entry's metadata.

## Access

Each kind gets its own Roles (a builder, a viewer) that nothing binds; the platform's rules (policy, quotas, the admission guard) apply to
what a definition may ask for, and not to who set a label. The admission guard in front of the controller is an allowlist of keys at every level:
a field the controller does not write is refused, so a kind that adds a field to what the controller writes changes the guard in the same change.
