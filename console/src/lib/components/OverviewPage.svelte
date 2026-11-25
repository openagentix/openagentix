<script lang="ts">
    // Overview (UI-SPEC 6.1): a landing page built only from what the console API reads (the agents list, the platform
    // catalog and the policy). Spend, turns and traces appear only when the API says metrics are available.
    import { ctx } from '$lib/context.svelte';
    import { formatTime } from '$lib/status';
    import { inUse, posture, recent } from '$lib/posture';
    import { useAgents } from '$lib/useagents.svelte';
    import { useMetrics } from '$lib/usemetrics.svelte';
    import { attention, countStates, ttlLine } from '$lib/views';
    import Icon from './Icon.svelte';
    import MetricsRow from './MetricsRow.svelte';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import Skeleton from './Skeleton.svelte';
    import StateBar from './StateBar.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import Tag from './Tag.svelte';

    const DOCS = 'https://openagentix.github.io';
    const src = useAgents();
    $effect(() => {
        void src.load();
    });

    const platform = $derived(ctx.platform);
    const metrics = useMetrics();
    $effect(() => {
        if (platform?.metrics?.available) void metrics.load('24h');
    });
    const counts = $derived(countStates(src.items));
    const needs = $derived(attention(src.items));
    const used = $derived(src.list?.used ?? 0);
    const max = $derived(platform?.policy.maxAgents ?? 0);
    const usage = $derived(platform ? inUse(src.items, platform) : null);
    const checks = $derived(platform ? posture(platform) : []);
    const warnings = $derived(checks.filter((c) => !c.ok).length);
    const latest = $derived(recent(src.items, 5));
    const builtReady = $derived(src.items.filter((a) => a.source === 'built' && a.state === 'ready').length);
    const example = $derived(src.items.find((a) => a.source === 'built')?.name);
    const showStart = $derived(counts.built < 3 || builtReady === 0);

    interface Card {
        label: string;
        icon: string;
        name: string;
        state: 'on' | 'off' | 'unknown';
        note: string;
    }
    const cards = $derived.by((): Card[] => {
        const p = platform;
        if (!p) return [];
        const t = (on: boolean): 'on' | 'off' => (on ? 'on' : 'off');
        return [
            { label: 'Runtime', icon: 'i-agent', name: p.adapters.runtime, state: 'on', note: 'runs the agents' },
            {
                label: 'Model gateway',
                icon: 'i-model',
                name: p.adapters.modelGateway,
                state: 'on',
                note: 'every model call goes through it',
            },
            {
                label: 'Tool gateway',
                icon: 'i-tool',
                name: p.adapters.tools,
                state: 'on',
                note: 'serves the tool profiles',
            },
            {
                label: 'A2A gate',
                icon: 'i-shield',
                name: p.gateEnabled ? 'a2a-gate' : '',
                state: t(p.gateEnabled),
                note: p.gateEnabled ? 'checks who calls an agent' : 'not installed: calls are not checked',
            },
            {
                label: 'Control plane',
                icon: 'i-gear',
                name: 'AgentDefinition',
                state: 'on',
                note: 'catalog and policy are loaded',
            },
            {
                label: 'Knowledge',
                icon: 'i-book',
                name: '',
                state: t(p.knowledge.available),
                note: p.knowledge.available ? 'an agent may search the knowledge base' : 'not installed',
            },
            {
                label: 'Memory',
                icon: 'i-memory',
                name: '',
                state: t(p.memory.available),
                note: p.memory.available
                    ? `expiry job ${p.memory.expiryEnabled ? 'on' : 'off'}, ${ttlLine(p)}`
                    : 'not installed',
            },
            {
                label: 'Notify',
                icon: 'i-send',
                name: '',
                state: t(p.notify.available),
                note: p.notify.available ? 'an agent may send a message to a chat' : 'not installed',
            },
            {
                label: 'Observability',
                icon: 'i-trace',
                name: '',
                state: 'unknown',
                note: 'the console does not read it in this release',
            },
        ];
    });
</script>

<svelte:head><title>Overview · OpenAgentix console</title></svelte:head>

<section class="view">
    <PageHeader title="Overview" strip="AgentDefinition list · platform catalog · platform policy" />

    {#if platform?.policy.suspendAll}
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
                <StateBar {counts} />
            </div>
            <div class="tile">
                <div class="lbl">Definitions used</div>
                <div class="val">{used}<small>of {max}</small></div>
                <progress class="meter-p" value={used} max={Math.max(max, 1)} aria-label="Definitions used of the limit"
                ></progress>
                <div class="cmp">
                    policy <code>maxAgents: {max}</code>{#if counts.chart > 0}&nbsp;· {counts.chart} chart
                        {counts.chart === 1 ? 'agent' : 'agents'} not counted{/if}
                </div>
            </div>
            {#if usage}
                <div class="tile">
                    <div class="lbl">Tool profiles in use</div>
                    <div class="val">{usage.profiles}<small>of {usage.profilesOf}</small></div>
                    <progress
                        class="meter-p"
                        value={usage.profiles}
                        max={Math.max(usage.profilesOf, 1)}
                        aria-label="Tool profiles in use"
                    ></progress>
                    <div class="cmp">profiles of the catalog that an agent names</div>
                </div>
                <div class="tile">
                    <div class="lbl">Models in use</div>
                    <div class="val">{usage.models}<small>of {usage.modelsOf}</small></div>
                    <progress
                        class="meter-p"
                        value={usage.models}
                        max={Math.max(usage.modelsOf, 1)}
                        aria-label="Models in use"
                    ></progress>
                    <div class="cmp">gateway models that an agent names</div>
                </div>
            {/if}
        </div>

        {#if metrics.error}
            <p class="sm t3">{metrics.error}</p>
        {/if}
        <MetricsRow summary={metrics.summary} />

        <div class="grid g2 ov-main">
            {#if platform}
                <section class="panel posture" aria-labelledby="ov-sec">
                    <div class="hd">
                        <h2 id="ov-sec">Security posture</h2>
                        <span class="badge {warnings ? 'st-pending' : 'st-ready'}">
                            <svg aria-hidden="true" focusable="false"
                                ><use href="#{warnings ? 's-pending' : 's-ready'}" /></svg
                            >{warnings ? `${warnings} to review` : 'All checks pass'}
                        </span>
                        <span class="acts"
                            ><a href="/governance">Open Governance <Icon name="i-chev" size={12} /></a></span
                        >
                    </div>
                    <ul class="posture-list">
                        {#each checks as c (c.id)}
                            <li class={c.ok ? 'ok' : 'warn'}>
                                <Icon name={c.ok ? 's-ready' : 's-pending'} size={16} />
                                <span><span class="sr-only">{c.ok ? 'Pass: ' : 'Warning: '}</span>{c.text}</span>
                            </li>
                        {/each}
                    </ul>
                </section>
            {/if}

            <section class="panel" aria-labelledby="ov-att">
                <div class="hd"><h2 id="ov-att">Needs attention</h2></div>
                {#if counts.total === 0}
                    <div class="bd"><p class="t2">There is no agent yet. Create one to get started.</p></div>
                {:else if needs.length === 0}
                    <div class="bd all-good">
                        <Icon name="s-ready" size={20} />
                        <div>
                            <b>Every agent is Ready.</b>
                            <div class="sm t3">
                                {counts.total}
                                {counts.total === 1 ? 'agent' : 'agents'} answer, nothing is refused or waiting.
                            </div>
                        </div>
                    </div>
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
        </div>

        {#if platform}
            <section aria-labelledby="ov-health" class="stack">
                <h2 id="ov-health" class="sec-title">Platform health <span class="sm t3">from the catalog</span></h2>
                <div class="grid g3 health">
                    {#each cards as c (c.label)}
                        <div class="hcard {c.state}">
                            <span class="ico"><Icon name={c.icon} /></span>
                            <div class="hbody">
                                <div class="row1">
                                    <b>{c.label}</b>
                                    {#if c.state === 'on'}<StatusBadge state="ready" word="On" />
                                    {:else if c.state === 'off'}<StatusBadge state="paused" word="Off" />
                                    {:else}<StatusBadge state="paused" word="Not read" />{/if}
                                </div>
                                {#if c.name}<code class="hname">{c.name}</code>{/if}
                                <div class="sm t3">{c.note}</div>
                            </div>
                        </div>
                    {/each}
                </div>
            </section>
        {/if}

        <div class="grid g2">
            {#if showStart}
                <section class="panel" aria-labelledby="ov-start">
                    <div class="hd"><h2 id="ov-start">Get started</h2></div>
                    <ol class="steps">
                        <li class={counts.built > 0 ? 'done' : ''}>
                            <Icon name={counts.built > 0 ? 's-ready' : 's-none'} size={16} />
                            <span>
                                {#if counts.built > 0}An agent exists{:else}<a href="/agents/new"
                                        >Create your first agent</a
                                    >{/if}
                            </span>
                        </li>
                        <li class={builtReady > 0 ? 'done' : ''}>
                            <Icon name={builtReady > 0 ? 's-ready' : 's-none'} size={16} />
                            <span>{builtReady > 0 ? 'An agent is Ready' : 'Get an agent to Ready'}</span>
                        </li>
                        <li>
                            <Icon name="s-none" size={16} />
                            <span>
                                {#if example}<a href="/agents/{encodeURIComponent(example)}"
                                        >Open <code>{example}</code> in the builder</a
                                    >{:else}<a href="/agents/new">Open the builder</a>{/if}
                            </span>
                        </li>
                        <li>
                            <Icon name="s-none" size={16} />
                            <span><a href="/governance">View the platform policy</a></span>
                        </li>
                        <li>
                            <Icon name="s-none" size={16} />
                            <span
                                ><a href={DOCS} rel="noopener noreferrer" target="_blank"
                                    >Read the docs <Icon name="i-ext" size={12} /></a
                                ></span
                            >
                        </li>
                    </ol>
                </section>
            {/if}
            <section class="panel" aria-labelledby="ov-recent">
                <div class="hd">
                    <h2 id="ov-recent">Recently updated</h2>
                    <span class="acts"><a href="/agents">All agents <Icon name="i-chev" size={12} /></a></span>
                </div>
                {#if latest.length === 0}
                    <div class="bd"><p class="t2">No agents yet.</p></div>
                {:else}
                    <ul class="recent">
                        {#each latest as a (a.name)}
                            <li>
                                <span class="dot d-{a.state}" aria-hidden="true"></span>
                                <a class="mono" href="/agents/{encodeURIComponent(a.name)}">{a.name}</a>
                                <span class="sm t3">{a.state === 'ready' ? 'Ready' : a.state}</span>
                                <span class="sm t3 when">{formatTime(a.updated)}</span>
                            </li>
                        {/each}
                    </ul>
                {/if}
            </section>
        </div>

        <p class="sm t3">
            {#if platform?.metrics?.available}Traces come with the observability adapter (ADR 0009).{:else}Costs and
                traces come with the observability adapter (ADR 0009). This page shows none of them until the console
                can read them.{/if}
        </p>
    {/if}
</section>
