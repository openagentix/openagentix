<script lang="ts">
    // Overview (UI-SPEC 6.1), with only what the console API reads: the agents list, the platform catalog and the policy.
    // No spend, turns, traces or recent changes: those have no source in this release, and the page says so once.
    import { ctx } from '$lib/context.svelte';
    import { segments } from '$lib/planned';
    import { formatTime } from '$lib/status';
    import { useAgents } from '$lib/useagents.svelte';
    import { attention, countStates, platformRows } from '$lib/views';
    import Icon from './Icon.svelte';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import Skeleton from './Skeleton.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import Tag from './Tag.svelte';

    const src = useAgents();
    $effect(() => {
        void src.load();
    });

    const platform = $derived(ctx.platform);
    const counts = $derived(countStates(src.items));
    const needs = $derived(attention(src.items));
    const used = $derived(src.list?.used ?? 0);
    const max = $derived(platform?.policy.maxAgents ?? 0);
    const pct = $derived(max > 0 ? Math.min(100, Math.round((used / max) * 100)) : 0);
    const policy = $derived(platform?.policy);
    const split: { key: 'ready' | 'pending' | 'refused' | 'error' | 'paused'; word: string }[] = [
        { key: 'ready', word: 'ready' },
        { key: 'pending', word: 'pending' },
        { key: 'refused', word: 'refused' },
        { key: 'error', word: 'failed' },
        { key: 'paused', word: 'paused' },
    ];
</script>

<svelte:head><title>Overview · OpenAgentix console</title></svelte:head>

<section class="view">
    <PageHeader title="Overview" strip="AgentDefinition list · platform catalog · platform policy" />

    {#if policy?.suspendAll}
        <Notice kind="warn" title="The operator's stop switch is on">
            <p class="sm">
                <code>suspendAll</code> is true in the platform policy, so every definition is treated as suspended: the runtime
                agents are removed and their gateway keys are cut. Nothing is wrong with the agents themselves.
            </p>
        </Notice>
    {/if}
    {#if src.error}
        <Notice kind="error" title="Could not read the agents"><p class="sm">{src.error}</p></Notice>
    {/if}
    {#if ctx.platformError}
        <Notice kind="error" title="Could not read the platform catalog and policy"
            ><p class="sm">{ctx.platformError}</p></Notice
        >
    {/if}
    {#if src.list?.truncated}
        <Notice kind="warn" title="Only part of the agents were read">
            <p class="sm">
                The console read the first {src.list.cap} agents of each kind, so the counts below are lower bounds.
            </p>
        </Notice>
    {/if}

    {#if src.loading && !src.list}
        <div class="grid g4" aria-busy="true">
            <span class="sr-only">Loading</span>
            {#each [0, 1, 2, 3] as i (i)}<div class="tile">
                    <Skeleton class="w-[50%]" /><Skeleton class="w-[30%]" />
                </div>{/each}
        </div>
    {:else if src.list}
        <div class="grid g4" role="group" aria-label="Totals">
            <div class="tile">
                <div class="lbl">Agents</div>
                <div class="val">{counts.total}</div>
                <div class="split">
                    {#each split as s (s.key)}
                        {#if counts[s.key] > 0 || s.key === 'ready' || s.key === 'pending' || s.key === 'refused' || s.key === 'paused'}
                            <span><span class="dot d-{s.key}"></span>{counts[s.key]} {s.word}</span>
                        {/if}
                    {/each}
                    <span><span class="dot d-chart"></span>{counts.chart} chart-managed</span>
                </div>
            </div>
            <div class="tile">
                <div class="lbl">Definitions used</div>
                <div class="val">{used}<small>of {max}</small></div>
                <div class="meter" aria-hidden="true"><i style:width="{pct}%"></i></div>
                <div class="cmp">
                    policy <code>maxAgents: {max}</code>{#if counts.chart > 0}
                        · {counts.chart} chart {counts.chart === 1 ? 'agent' : 'agents'} not counted{/if}
                </div>
            </div>
            <div class="tile">
                <div class="lbl">Needs attention</div>
                <div class="val">{needs.length}</div>
                <div class="cmp">
                    {needs.length === 0 ? 'every agent is Ready' : 'agents that are not Ready, listed below'}
                </div>
            </div>
            <div class="tile">
                <div class="lbl">Chart-managed</div>
                <div class="val">{counts.chart}</div>
                <div class="cmp">read-only here; set in chart values under <code>agents[]</code></div>
            </div>
        </div>

        <div class="grid g2">
            <section class="panel" aria-labelledby="ov-att">
                <div class="hd"><h2 id="ov-att">Needs attention</h2></div>
                {#if needs.length === 0}
                    <div class="bd"><p class="t2">Every agent is Ready.</p></div>
                {:else}
                    <div class="tw">
                        <table class="mini">
                            <caption class="sr-only">Agents that are not Ready, with the reason</caption>
                            <tbody>
                                {#each needs as n (n.name)}
                                    <tr>
                                        <td><StatusBadge state={n.state} deleting={n.deleting} /></td>
                                        <td>
                                            <a class="mono" href="/agents/{encodeURIComponent(n.name)}">{n.name}</a>
                                            {#if n.source === 'chart'}<Tag>Chart</Tag>{/if}
                                            {#if n.reason}<div class="sm t3 reason">{n.reason}</div>{/if}
                                        </td>
                                        <td class="sm t3 r">{formatTime(n.updated)}</td>
                                    </tr>
                                {/each}
                            </tbody>
                        </table>
                    </div>
                {/if}
            </section>

            <section class="panel" aria-labelledby="ov-plat">
                <div class="hd">
                    <h2 id="ov-plat">Platform</h2>
                    <span class="sm t3">active adapters and optional components</span>
                </div>
                <div class="bd">
                    {#if platform}
                        <dl class="kv">
                            {#each platformRows(platform) as r (r.label)}
                                <dt>{r.label}</dt>
                                <dd>
                                    {#if r.value}<code>{r.value}</code>{#if r.note}<span class="t3">
                                                · {r.note}</span
                                            >{/if}
                                    {:else}
                                        <span class="onoff {r.on ? 'on' : 'off'}"
                                            ><Icon name={r.on ? 's-ready' : 's-paused'} size={12} />{r.on
                                                ? 'On'
                                                : 'Off'}</span
                                        >
                                        <span class="t3">
                                            {#each segments(r.note.replace(/^(on|off)[:,] ?/, '')) as seg, i (i)}{#if seg.code}<code
                                                        >{seg.text}</code
                                                    >{:else}{seg.text}{/if}{/each}
                                        </span>
                                    {/if}
                                </dd>
                            {/each}
                        </dl>
                    {:else}
                        <p class="t3">The platform catalog could not be read.</p>
                    {/if}
                </div>
            </section>
        </div>

        {#if policy}
            <section class="panel" aria-labelledby="ov-pol">
                <div class="hd">
                    <h2 id="ov-pol">Platform policy</h2>
                    <span class="sm t3">what a definition may use</span>
                    <span class="acts"><a href="/governance">Open Governance <Icon name="i-chev" size={12} /></a></span>
                </div>
                <div class="bd">
                    <ul class="chips">
                        <li>at most {policy.maxAgents} definitions</li>
                        <li>models: {policy.allowedModels.length ? policy.allowedModels.join(', ') : 'none'}</li>
                        <li>
                            tool profile {policy.requireToolProfile ? 'required' : 'optional'}: {policy.allowedProfiles
                                .length
                                ? policy.allowedProfiles.join(', ')
                                : 'none allowed'}
                        </li>
                        <li>knowledge {policy.allowKnowledge ? 'allowed' : 'not allowed'}</li>
                        <li>notify {policy.allowNotify ? 'allowed' : 'not allowed'}</li>
                        <li>
                            memory {policy.memory.allowed
                                ? `allowed, at most ${policy.memory.maxTtlDays} days`
                                : 'not allowed'}
                        </li>
                        <li>{policy.egress.allowedOrigins.length} allowed egress origins</li>
                    </ul>
                </div>
            </section>
        {/if}

        <p class="sm t3">
            Costs and traces come with the observability adapter (ADR 0009). This page shows none of them until the
            console can read them.
        </p>
    {/if}
</section>
