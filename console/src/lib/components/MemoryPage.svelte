<script lang="ts">
    // Memory (UI-SPEC 6.11), read-only: whether the memory stack is installed, the limits, and which agents remember.
    // The counts of the expiry job are not read in this release, and the page says so.
    import { READONLY } from '$lib/planned';
    import { useAgents } from '$lib/useagents.svelte';
    import { ttlLine } from '$lib/views';
    import Notice from './Notice.svelte';
    import PlatformGate from './PlatformGate.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import Tag from './Tag.svelte';

    const c = READONLY['memory']!;
    const src = useAgents();
    $effect(() => {
        void src.load();
    });
</script>

<PlatformGate title={c.title} strip={c.strip} noticeTitle={c.noticeTitle} notice={c.notice}>
    {#snippet children(p)}
        {@const remembering = src.items.filter((a) => a.memory?.enabled).sort((a, b) => a.name.localeCompare(b.name))}
        {#if src.error}<Notice kind="error" title="Could not read the agents"><p class="sm">{src.error}</p></Notice
            >{/if}
        <div class="grid g2">
            <section class="panel" aria-labelledby="mem-stack">
                <div class="hd">
                    <h2 id="mem-stack">Memory on this platform</h2>
                    <StatusBadge
                        state={p.memory.available ? 'ready' : 'paused'}
                        word={p.memory.available ? 'Available' : 'Not installed'}
                    />
                </div>
                <div class="bd stack">
                    <dl class="kv sm">
                        <dt>Memory stack</dt>
                        <dd>
                            {p.memory.available
                                ? 'installed: an agent may remember across conversations'
                                : 'not installed: no agent can remember'}
                        </dd>
                        <dt>Expiry job</dt>
                        <dd>
                            {#if p.memory.expiryEnabled}<code>memory-expiry</code> is on: memories older than their time to
                                live are removed{:else}off: memories are not removed when they expire{/if}
                        </dd>
                        <dt>Time to live</dt>
                        <dd>{ttlLine(p)}</dd>
                        <dt>Policy</dt>
                        <dd>
                            {#if p.policy.memory.allowed}
                                allowed{p.policy.memory.requireExpiry ? ', and the expiry job must be on' : ''}
                            {:else}
                                not allowed: a definition that turns memory on is refused
                            {/if}
                        </dd>
                    </dl>
                    <p class="sm t3">
                        The console has no source for the counts of the expiry job (memories kept, expired, deleted), so
                        it shows none. A person's memories are never listed in the console.
                    </p>
                </div>
            </section>
            <section class="panel" aria-labelledby="mem-agents">
                <div class="hd"><h2 id="mem-agents">Agents that remember</h2></div>
                {#if src.loading && !src.list}
                    <div class="bd"><p class="t3">Loading the agents.</p></div>
                {:else if remembering.length === 0}
                    <div class="bd"><p class="t2">No agent has memory on.</p></div>
                {:else}
                    <div class="tw">
                        <table class="mini">
                            <thead><tr><th>Agent</th><th>Keeps for</th><th>Source</th></tr></thead>
                            <tbody>
                                {#each remembering as a (a.name)}
                                    <tr>
                                        <td><a class="mono" href="/agents/{encodeURIComponent(a.name)}">{a.name}</a></td
                                        >
                                        <td>
                                            {#if a.memory?.ttlDays}{a.memory.ttlDays} days{:else}{p.memory
                                                    .defaultTtlDays} days
                                                <span class="t3">(catalog default)</span>{/if}
                                        </td>
                                        <td>
                                            {#if a.source === 'chart'}<Tag>Chart</Tag>{:else}<Tag variant="accent"
                                                    >Built</Tag
                                                >{/if}
                                        </td>
                                    </tr>
                                {/each}
                            </tbody>
                        </table>
                    </div>
                {/if}
            </section>
        </div>
    {/snippet}
</PlatformGate>
