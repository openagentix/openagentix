<script lang="ts">
    import { goto } from '$app/navigation';
    import { api, describeError } from '$lib/api';
    import { ctx } from '$lib/context.svelte';
    import { isTypingTarget } from '$lib/nav';
    import { startPolling } from '$lib/poll.svelte';
    import { absoluteTime, formatTime, memoryTag, stateWord, unsettled } from '$lib/status';
    import type { Agent, AgentList, State } from '$lib/types';
    import Button from './Button.svelte';
    import ConditionRail from './ConditionRail.svelte';
    import EmptyState from './EmptyState.svelte';
    import Icon from './Icon.svelte';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import Segmented from './Segmented.svelte';
    import Skeleton from './Skeleton.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import Tag from './Tag.svelte';

    let list = $state<AgentList | null>(null);
    let error = $state('');
    let loading = $state(true);
    let slow = $state(false);
    let query = $state('');
    let source = $state('all');
    let statusFilter = $state('all');
    let sortKey = $state<'name' | 'status' | 'updated'>('name');
    let sortDir = $state<'ascending' | 'descending'>('ascending');

    async function load(quiet = false) {
        if (!quiet) {
            loading = true;
            slow = false;
        }
        const t = setTimeout(() => (slow = true), 8000);
        try {
            list = await api.agents();
            error = '';
        } catch (e) {
            if (!quiet || !list) error = describeError('read', 'the agents', e);
        } finally {
            clearTimeout(t);
            loading = false;
            slow = false;
        }
    }

    const poller = startPolling({
        run: () => load(true),
        active: () => !!list && list.items.some((a) => unsettled(a)),
    });
    $effect(() => {
        void load();
        return () => poller.stop();
    });
    $effect(() => {
        void list;
        poller.kick();
    });

    const maxAgents = $derived(ctx.platform?.policy.maxAgents);
    const canWrite = $derived(ctx.session?.canWrite ?? false);
    const limitReached = $derived(maxAgents !== undefined && list !== null && list.used >= maxAgents);
    const rank: Record<State, number> = { refused: 0, error: 1, pending: 2, paused: 3, ready: 4 };

    const rows = $derived.by(() => {
        const q = query.trim().toLowerCase();
        const items = (list?.items ?? []).filter(
            (a) =>
                (!q || a.name.toLowerCase().includes(q)) &&
                (source === 'all' || a.source === source) &&
                (statusFilter === 'all' || a.state === statusFilter),
        );
        const dir = sortDir === 'ascending' ? 1 : -1;
        return [...items].sort((a, b) => {
            if (sortKey === 'status') return (rank[a.state] - rank[b.state] || a.name.localeCompare(b.name)) * dir;
            if (sortKey === 'updated') return ((Date.parse(a.updated) || 0) - (Date.parse(b.updated) || 0)) * dir;
            return a.name.localeCompare(b.name) * dir;
        });
    });

    function sortBy(k: 'name' | 'status' | 'updated') {
        if (sortKey === k) sortDir = sortDir === 'ascending' ? 'descending' : 'ascending';
        else {
            sortKey = k;
            sortDir = k === 'updated' ? 'descending' : 'ascending';
        }
    }
    const ariaSort = (k: string) => (sortKey === k ? sortDir : 'none');

    function open(name: string) {
        void goto(`/agents/${encodeURIComponent(name)}`);
    }
    function rowClick(e: MouseEvent, name: string) {
        if ((e.target as HTMLElement).closest('a,button')) return;
        open(name);
    }
    function onkey(e: KeyboardEvent) {
        if (
            e.key === 'n' &&
            !e.ctrlKey &&
            !e.metaKey &&
            !e.altKey &&
            !isTypingTarget(e.target) &&
            canWrite &&
            !limitReached
        ) {
            e.preventDefault();
            void goto('/agents/new');
        }
    }
    const newReason = $derived(
        !canWrite
            ? 'This console is read-only, so it cannot create agents.'
            : limitReached
              ? `The platform policy allows at most ${maxAgents} agents and ${list?.used} already exist.`
              : undefined,
    );
    const filtered = $derived(query.trim() !== '' || source !== 'all' || statusFilter !== 'all');
</script>

<svelte:window onkeydown={onkey} />
<svelte:head><title>Agents · OpenAgentix console</title></svelte:head>

<section class="view">
    <PageHeader title="Agents" strip="AgentDefinition · openagentix.io/v1alpha1 · chart agents[]">
        {#snippet actions()}
            <Button
                variant="primary"
                disabledReason={newReason}
                onclick={() => goto('/agents/new')}
                aria-keyshortcuts="n"><Icon name="i-plus" />New agent</Button
            >
        {/snippet}
    </PageHeader>

    {#if list?.warnings.length}
        <Notice kind="warn" title="Some details could not be read">
            {#each list.warnings as w (w)}<p class="sm">{w}</p>{/each}
        </Notice>
    {/if}

    {#if list?.truncated}
        <Notice kind="warn" title="The list is cut">
            <p class="sm" data-testid="truncated">
                Showing the first {list.cap} agents of each kind. The cluster holds more. Use
                <code>kubectl get agentdefinitions</code> to see all of them.
            </p>
        </Notice>
    {/if}

    <div class="panel">
        <div class="toolbar">
            <input
                class="input"
                id="agent-filter"
                type="search"
                placeholder="Filter by name"
                aria-label="Filter agents by name"
                bind:value={query}
                autocomplete="off"
            />
            <Segmented
                label="Source"
                value={source}
                options={[
                    { id: 'all', label: 'All' },
                    { id: 'built', label: 'Built' },
                    { id: 'chart', label: 'Chart' },
                ]}
                onselect={(id) => (source = id)}
            />
            <select class="input" aria-label="Filter by status" bind:value={statusFilter}>
                <option value="all">Any status</option>
                <option value="ready">Ready</option>
                <option value="pending">Pending</option>
                <option value="refused">Refused</option>
                <option value="error">Failed</option>
                <option value="paused">Paused</option>
            </select>
            {#if list && maxAgents !== undefined}
                <span class="sm t3 ml-auto" data-testid="used"
                    ><span class="num">{list.used}</span> of {maxAgents} definitions used (policy
                    <code>maxAgents: {maxAgents}</code>)</span
                >
            {/if}
        </div>

        <div class="tw" aria-busy={loading}>
            {#if error}
                <div class="p-4">
                    <Notice kind="error" title="Could not read the agents" alert>
                        <p class="sm">{error}</p>
                        {#snippet action()}<Button small onclick={() => load()}>Retry</Button>{/snippet}
                    </Notice>
                </div>
            {:else if loading && !list}
                <span class="sr">Loading</span>
                <table aria-hidden="true">
                    <tbody>
                        {#each [0, 1, 2, 3, 4] as i (i)}
                            <tr
                                ><td><Skeleton class="w-[140px]" /></td><td><Skeleton class="w-[70px]" /></td><td
                                    ><Skeleton class="w-[50px]" /></td
                                ><td><Skeleton class="w-[90px]" /></td><td><Skeleton class="w-[60px]" /></td><td
                                    ><Skeleton class="w-[100px]" /></td
                                ><td><Skeleton class="w-[50px]" /></td><td><Skeleton class="w-[60px]" /></td></tr
                            >
                        {/each}
                    </tbody>
                </table>
                {#if slow}<p class="sm t3 p-3">Still waiting for the console API.</p>{/if}
            {:else if list && list.items.length === 0}
                <EmptyState title="No agents yet." icon="i-agent">
                    <p>Create one here, or apply an <code>AgentDefinition</code> with kubectl.</p>
                    {#snippet action()}<Button
                            variant="primary"
                            disabledReason={newReason}
                            onclick={() => goto('/agents/new')}><Icon name="i-plus" />New agent</Button
                        >{/snippet}
                </EmptyState>
            {:else if rows.length === 0}
                <EmptyState title="No agent matches" icon="i-search" level={2}
                    ><p>
                        Nothing in the registry matches {filtered ? 'this filter' : 'that'}. Clear the filter to see all {list
                            ?.items.length} agents.
                    </p></EmptyState
                >
            {:else}
                <table id="agentTable">
                    <thead>
                        <tr>
                            <th aria-sort={ariaSort('name')}
                                ><button type="button" onclick={() => sortBy('name')}
                                    >Name <Icon
                                        name="i-chev"
                                        class={sortKey === 'name'
                                            ? sortDir === 'ascending'
                                                ? 'rotate-90'
                                                : '-rotate-90'
                                            : 'opacity-30 rotate-90'}
                                        size={12}
                                    /></button
                                ></th
                            >
                            <th aria-sort={ariaSort('status')}
                                ><button type="button" onclick={() => sortBy('status')}
                                    >Status <Icon
                                        name="i-chev"
                                        class={sortKey === 'status'
                                            ? sortDir === 'ascending'
                                                ? 'rotate-90'
                                                : '-rotate-90'
                                            : 'opacity-30 rotate-90'}
                                        size={12}
                                    /></button
                                ></th
                            >
                            <th>Conditions</th>
                            <th>Model</th>
                            <th>Tool profile</th>
                            <th>Capabilities</th>
                            <th>Source</th>
                            <th class="r" aria-sort={ariaSort('updated')}
                                ><button type="button" onclick={() => sortBy('updated')}
                                    >Updated <Icon
                                        name="i-chev"
                                        class={sortKey === 'updated'
                                            ? sortDir === 'ascending'
                                                ? 'rotate-90'
                                                : '-rotate-90'
                                            : 'opacity-30 rotate-90'}
                                        size={12}
                                    /></button
                                ></th
                            >
                        </tr>
                    </thead>
                    <tbody>
                        {#each rows as a (a.name)}
                            {@render row(a)}
                        {/each}
                    </tbody>
                </table>
            {/if}
        </div>
    </div>
</section>

{#snippet row(a: Agent)}
    {@const mem = memoryTag(a.memory)}
    <tr class="clk" onclick={(e) => rowClick(e, a.name)} data-agent={a.name}>
        <td>
            <a class="mono" href="/agents/{encodeURIComponent(a.name)}">{a.name}</a>
            {#if a.state === 'refused' && a.stateReason}
                <div class="sm text-refused line-clamp-2" title={a.stateReason}>{a.stateReason}</div>
            {:else if a.state === 'pending' || a.state === 'error'}
                <div class="sm t3 line-clamp-2" title={a.stateReason}>{a.stateReason || a.description}</div>
            {:else if a.description}
                <div class="sm t3">{a.description}</div>
            {/if}
        </td>
        <td
            ><StatusBadge
                state={a.state}
                deleting={a.deleting}
                title={a.stateReason || stateWord(a.state, a.deleting)}
            /></td
        >
        <td>
            {#if a.source === 'chart'}<span class="t3 sm">chart-managed</span>{:else}<ConditionRail
                    conditions={a.conditions}
                    compact
                />{/if}
        </td>
        <td class="mono">{a.model || '—'}</td>
        <td class={a.toolProfile ? 'mono' : 't3'}
            >{a.toolProfile || (a.source === 'chart' && a.toolsCount > 0 ? 'None (shared vMCP)' : 'None')}</td
        >
        <td>
            <div class="tags">
                {#if a.runtimeType === 'container'}<Tag>container{a.isolation ? ` · ${a.isolation}` : ''}</Tag>{/if}
                {#if a.knowledge}<Tag>knowledge</Tag>{/if}
                {#if a.notify}<Tag>notify</Tag>{/if}
                {#if mem}<Tag>{mem}</Tag>{/if}
                {#if a.skills.length}<Tag>skills {a.skills.length}</Tag>{/if}
                {#if a.egressCount}<Tag>egress {a.egressCount}</Tag>{/if}
                {#if a.team}<Tag title="label openagentix.io/team">team {a.team}</Tag>{/if}
                {#if a.project}<Tag title="label openagentix.io/project">project {a.project}</Tag>{/if}
            </div>
        </td>
        <td
            ><Tag variant={a.source === 'built' ? 'accent' : 'neutral'}>{a.source === 'built' ? 'Built' : 'Chart'}</Tag
            ></td
        >
        <td class="r sm t3" title={absoluteTime(a.updated)}>{formatTime(a.updated)}</td>
    </tr>
{/snippet}
