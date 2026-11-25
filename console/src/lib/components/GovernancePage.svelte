<script lang="ts">
    // Governance (UI-SPEC 6.12), read-only and owned by operators: the platform policy as a summary and as YAML, the egress and
    // tools each agent really got (from the status), and an honest line about the gate caller rules, which the console cannot read.
    import { READONLY } from '$lib/planned';
    import { useAgents } from '$lib/useagents.svelte';
    import { policyYaml } from '$lib/views';
    import Button from './Button.svelte';
    import CodeViewer from './CodeViewer.svelte';
    import Notice from './Notice.svelte';
    import PlatformGate from './PlatformGate.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import Tabs from './Tabs.svelte';
    import Tag from './Tag.svelte';

    const c = READONLY['governance']!;
    const src = useAgents();
    $effect(() => {
        void src.load();
    });
    let tab = $state('policy');
    const TABS = [
        { id: 'policy', label: 'Policy' },
        { id: 'egress', label: 'Egress and tools' },
        { id: 'callers', label: 'Gate callers' },
        { id: 'yaml', label: 'YAML' },
    ];
</script>

<PlatformGate title={c.title} strip={c.strip} noticeTitle={c.noticeTitle} notice={c.notice}>
    {#snippet actions()}
        <Button onclick={() => (tab = 'yaml')}>View YAML</Button>
    {/snippet}
    {#snippet children(p)}
        {@const pol = p.policy}
        {@const rows = [...src.items].sort((a, b) => a.name.localeCompare(b.name))}
        {#if pol.suspendAll}
            <Notice kind="warn" title="The operator's stop switch is on">
                <p class="sm">
                    <code>suspendAll</code> is true: every definition is treated as suspended, and the runtime agents are
                    removed.
                </p>
            </Notice>
        {/if}
        <Tabs label="Governance" prefix="g" selected={tab} tabs={TABS} onselect={(id) => (tab = id)} />

        <div role="tabpanel" id="g-panel-{tab}" aria-labelledby="g-tab-{tab}" class="stack">
            {#if tab === 'policy'}
                <div class="grid g2">
                    <section class="panel" aria-labelledby="gv-may">
                        <div class="hd"><h2 id="gv-may">What a definition may use</h2></div>
                        <div class="bd">
                            <dl class="kv">
                                <dt>Agents</dt>
                                <dd>
                                    at most {pol.maxAgents} definitions{#if src.list}
                                        · {src.list.used} used{/if}
                                </dd>
                                <dt>Models</dt>
                                <dd>
                                    {#each pol.allowedModels as m, i (m)}{#if i > 0},
                                        {/if}<code>{m}</code>{:else}none{/each}
                                </dd>
                                <dt>Tool profile</dt>
                                <dd>
                                    {pol.requireToolProfile ? 'required' : 'optional'} · allowed
                                    {#each pol.allowedProfiles as m, i (m)}{#if i > 0},
                                        {/if}<code>{m}</code>{:else}none{/each}
                                </dd>
                                <dt>Knowledge</dt>
                                <dd>{pol.allowKnowledge ? 'allowed' : 'not allowed'}</dd>
                                <dt>Notify</dt>
                                <dd>{pol.allowNotify ? 'allowed' : 'not allowed'}</dd>
                                <dt>Memory</dt>
                                <dd>
                                    {#if pol.memory.allowed}allowed · at most {pol.memory.maxTtlDays} days{pol.memory
                                            .requireExpiry
                                            ? ' · expiry job required'
                                            : ''}{:else}not allowed{/if}
                                </dd>
                                <dt>Skills</dt>
                                <dd>
                                    {#each pol.allowedSkills as m, i (m)}{#if i > 0},
                                        {/if}<code>{m}</code>{:else}none{/each}
                                </dd>
                                <dt>Egress</dt>
                                <dd>
                                    {#each pol.egress.allowedOrigins as m, i (m)}{#if i > 0},
                                        {/if}<code>{m}</code>{:else}none{/each}
                                </dd>
                                <dt>Reserved names</dt>
                                <dd>
                                    {#each [...new Set( [...p.reservedNames, ...pol.reservedNames] )] as m, i (m)}{#if i > 0},
                                        {/if}<code>{m}</code>{:else}none{/each}
                                </dd>
                            </dl>
                        </div>
                    </section>
                    <section class="panel" aria-labelledby="gv-always">
                        <div class="hd"><h2 id="gv-always">Always enforced</h2></div>
                        <div class="bd">
                            <ul class="sm t2 plain-list">
                                <li>
                                    Tools only through a tool profile; the shared tool server filters on the client side
                                    only.
                                </li>
                                <li>No outbound access unless an origin matches the policy.</li>
                                <li>Nobody may call a built agent until an operator adds a gate caller rule.</li>
                                <li>Instructions are scanned for eleven secret shapes.</li>
                                <li>Each agent has its own gateway key and token budget.</li>
                                <li>The output guard limits what even the controller may write.</li>
                            </ul>
                        </div>
                    </section>
                </div>
                <section class="panel" aria-labelledby="gv-eg">
                    <div class="hd"><h2 id="gv-eg">Egress the policy allows</h2></div>
                    <div class="bd">
                        <dl class="kv">
                            <dt>Allowed origins</dt>
                            <dd>
                                <span class="tags"
                                    >{#each pol.egress.allowedOrigins as o (o)}<Tag>{o}</Tag>{:else}<span class="t3"
                                            >none: no built agent may reach the internet</span
                                        >{/each}</span
                                >
                            </dd>
                            <dt>In-cluster destinations</dt>
                            <dd>
                                <span class="tags"
                                    >{#each pol.egress.inClusterDestinations ?? [] as o (o)}<Tag>{o}</Tag>{:else}<span
                                            class="t3">none: every in-cluster destination is refused</span
                                        >{/each}</span
                                >
                            </dd>
                        </dl>
                        <p class="sm t3 mt-3">
                            A wildcard origin such as <code>https://*.example.org</code> stands for exactly one label.
                        </p>
                    </div>
                </section>
            {:else if tab === 'egress'}
                {#if src.error}<Notice kind="error" title="Could not read the agents"
                        ><p class="sm">{src.error}</p></Notice
                    >{/if}
                <section class="panel" aria-labelledby="gv-per">
                    <div class="hd">
                        <h2 id="gv-per">What each agent really got</h2>
                        <span class="sm t3"
                            >from <code>status.effectiveEgress</code> and <code>status.effectiveTools</code></span
                        >
                    </div>
                    {#if rows.length === 0}
                        <div class="bd">
                            <p class="t2">{src.loading ? 'Loading the agents.' : 'There is no agent yet.'}</p>
                        </div>
                    {:else}
                        <div class="tw">
                            <table>
                                <thead>
                                    <tr
                                        ><th>Agent</th><th>Status</th><th>Tool profile</th><th>Effective tools</th><th
                                            >Effective egress</th
                                        ></tr
                                    >
                                </thead>
                                <tbody>
                                    {#each rows as a (a.name)}
                                        <tr>
                                            <td
                                                ><a class="mono" href="/agents/{encodeURIComponent(a.name)}">{a.name}</a
                                                ></td
                                            >
                                            <td><StatusBadge state={a.state} deleting={a.deleting} /></td>
                                            {#if a.source === 'chart'}
                                                <td class="mono">{a.toolProfile || '—'}</td>
                                                <td class="t3" colspan="2"
                                                    >not read for chart agents: they are set in chart values</td
                                                >
                                            {:else}
                                                <td class="mono">{a.toolProfile || '—'}</td>
                                                <td>
                                                    {#if a.effectiveTools.length}<span class="tags"
                                                            >{#each a.effectiveTools as t (t)}<Tag>{t}</Tag
                                                                >{/each}</span
                                                        >{:else}<span class="t3"
                                                            >{a.state === 'refused' ? 'none (refused)' : 'none'}</span
                                                        >{/if}
                                                </td>
                                                <td>
                                                    {#if a.effectiveEgress.length}<span class="tags"
                                                            >{#each a.effectiveEgress as t (t)}<Tag>{t}</Tag
                                                                >{/each}</span
                                                        >{:else}<span class="t3"
                                                            >{a.state === 'refused' ? 'none (refused)' : 'none'}</span
                                                        >{/if}
                                                </td>
                                            {/if}
                                        </tr>
                                    {/each}
                                </tbody>
                            </table>
                        </div>
                    {/if}
                </section>
            {:else if tab === 'callers'}
                <section class="panel" aria-labelledby="gv-call">
                    <div class="hd"><h2 id="gv-call">Gate callers</h2></div>
                    <div class="bd">
                        <p class="t2">
                            The A2A gate is {p.gateEnabled ? 'on' : 'off'}. Its caller rules (<code
                                >governance.a2a.callers</code
                            >) have no source in the console API, so they are not listed here. Read them in chart values
                            or Git.
                        </p>
                    </div>
                </section>
            {:else}
                <section aria-labelledby="gv-yaml" class="stack">
                    <h2 id="gv-yaml" class="sr-only">Platform policy as YAML</h2>
                    <CodeViewer code={policyYaml(pol)} label="Platform policy YAML" />
                    <p class="sm t3">
                        Written from the policy file the console reads (<code>control-plane-policy</code>), in the order
                        of the control-plane README.
                    </p>
                </section>
            {/if}
        </div>
    {/snippet}
</PlatformGate>
