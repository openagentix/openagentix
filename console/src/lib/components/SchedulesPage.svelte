<script lang="ts">
    // Schedules (UI-SPEC 6.9), read-only: the schedules the chart defines, read from their CronJobs. The prompt, the token and the user id
    // are not read. The console does not read Jobs, so the outcome of single runs is not shown; the CronJob's own times are.
    import { api, describeError } from '$lib/api';
    import { describeCron } from '$lib/govern';
    import { READONLY } from '$lib/planned';
    import { absoluteTime, formatTime } from '$lib/status';
    import type { Schedule, ScheduleList } from '$lib/types';
    import EmptyState from './EmptyState.svelte';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import SideSheet from './SideSheet.svelte';
    import Skeleton from './Skeleton.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import { segments } from '$lib/planned';

    const c = READONLY['schedules']!;
    let list = $state<ScheduleList | null>(null);
    let error = $state('');
    let picked = $state<Schedule | null>(null);

    $effect(() => {
        const ac = new AbortController();
        api.schedules(ac.signal)
            .then((l) => {
                list = l;
                error = '';
            })
            .catch((e) => {
                if (e instanceof DOMException && e.name === 'AbortError') return;
                error = describeError('read', 'the schedules', e);
            });
        return () => ac.abort();
    });
    const strip = $derived(
        `CronJob · namespace ${list?.namespace || 'openagentix-schedules'} · chart values schedules`,
    );
    const rows = $derived(list?.items ?? []);
</script>

<svelte:head><title>{c.title} · OpenAgentix console</title></svelte:head>

<section class="view max-form">
    <PageHeader title={c.title} {strip} />
    <Notice kind="ro" title={c.noticeTitle}>
        <p class="sm">
            {#each segments(c.notice) as seg, i (i)}{#if seg.code}<code>{seg.text}</code>{:else}{seg.text}{/if}{/each}
        </p>
    </Notice>
    {#if error}
        <Notice kind="error" title="Could not read the schedules"><p class="sm">{error}</p></Notice>
    {:else if !list}
        <div class="panel" aria-busy="true">
            <div class="bd stack">
                <span class="sr-only">Loading</span>
                <Skeleton class="w-[40%]" /><Skeleton class="w-full" /><Skeleton class="w-[70%]" />
            </div>
        </div>
    {:else if rows.length === 0}
        <div class="panel">
            <EmptyState icon="i-clock" title="No schedules are defined">
                {#if list.configured}
                    <p>
                        The namespace <code>{list.namespace}</code> holds no schedule from the chart. Add them under
                        <code>schedules</code> in chart values, then run <code>install.sh</code>.
                    </p>
                {:else}
                    <p>
                        The chart defines no schedule. Add them under <code>schedules</code> in chart values, then run
                        <code>install.sh</code>. Every firing is at least one model call.
                    </p>
                {/if}
            </EmptyState>
        </div>
    {:else}
        <section class="panel" aria-labelledby="sc-h">
            <div class="hd">
                <h2 id="sc-h">Schedules defined in chart values</h2>
                <span class="sm t3">{rows.length} in total</span>
            </div>
            <div class="tw">
                <table>
                    <thead>
                        <tr><th>Schedule</th><th>Agent</th><th>When</th><th>State</th><th>Last started</th></tr>
                    </thead>
                    <tbody>
                        {#each rows as s (s.name)}
                            {@const words = describeCron(s.cron)}
                            <tr>
                                <td>
                                    <button class="rowbtn mono" type="button" onclick={() => (picked = s)}
                                        >{s.name}</button
                                    >
                                </td>
                                <td class="mono">{s.agent || '—'}</td>
                                <td>
                                    {#if words}{words}{:else}<code>{s.cron}</code>{/if}
                                    {#if s.timeZone}<span class="t3"> · {s.timeZone}</span>{/if}
                                </td>
                                <td>
                                    <StatusBadge
                                        state={s.state === 'active' ? 'ready' : 'paused'}
                                        word={s.state === 'active' ? 'Active' : 'Suspended'}
                                    />
                                </td>
                                <td>{s.lastScheduled ? formatTime(s.lastScheduled) : 'Never'}</td>
                            </tr>
                        {/each}
                    </tbody>
                </table>
            </div>
        </section>
        <p class="sm t3">
            The times come from the CronJob. The console does not read single runs, so it does not say whether the last
            run worked. The prompt and the user id of a schedule are not shown.
        </p>
    {/if}
</section>

{#if picked}
    {@const s = picked}
    {@const words = describeCron(s.cron)}
    <SideSheet title={s.name} onclose={() => (picked = null)}>
        <dl class="kv sm">
            <dt>Agent</dt>
            <dd class="mono">{s.agent || 'not known'}</dd>
            <dt>Cron expression</dt>
            <dd><code>{s.cron}</code></dd>
            {#if words}
                <dt>In words</dt>
                <dd>{words}</dd>
            {/if}
            <dt>Time zone</dt>
            <dd>{s.timeZone || 'the cluster default'}</dd>
            <dt>State</dt>
            <dd>{s.state === 'active' ? 'Active' : 'Suspended'}</dd>
            <dt>Running now</dt>
            <dd>{s.active}</dd>
            <dt>Overlap</dt>
            <dd>{s.concurrencyPolicy || 'not known'}</dd>
            <dt>Call timeout</dt>
            <dd>{s.timeout || 'not known'}</dd>
            <dt>Last started</dt>
            <dd>{absoluteTime(s.lastScheduled) || 'Never'}</dd>
            <dt>Last succeeded</dt>
            <dd>{absoluteTime(s.lastSucceeded) || 'Never'}</dd>
            <dt>Created</dt>
            <dd>{absoluteTime(s.created) || 'not known'}</dd>
            <dt>Namespace</dt>
            <dd class="mono">{list?.namespace}</dd>
        </dl>
        <p class="sm t3 mt-3">Change or remove a schedule under <code>schedules</code> in chart values.</p>
    </SideSheet>
{/if}
