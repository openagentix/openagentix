<script lang="ts">
    // Access (UI-SPEC 6.12, gate callers), read-only: who may call which agent through the A2A gate, read from the gate's rules ConfigMap.
    // Only names, agents and methods are shown. A key, a key hash and a user id value are never read, because a user id can name a person.
    import { api, describeError } from '$lib/api';
    import { methodWords, ruleWords } from '$lib/govern';
    import { READONLY, segments } from '$lib/planned';
    import type { AccessList, Caller } from '$lib/types';
    import EmptyState from './EmptyState.svelte';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import SideSheet from './SideSheet.svelte';
    import Skeleton from './Skeleton.svelte';
    import Tag from './Tag.svelte';

    const c = READONLY['access']!;
    let list = $state<AccessList | null>(null);
    let error = $state('');
    let picked = $state<Caller | null>(null);

    $effect(() => {
        const ac = new AbortController();
        api.access(ac.signal)
            .then((l) => {
                list = l;
                error = '';
            })
            .catch((e) => {
                if (e instanceof DOMException && e.name === 'AbortError') return;
                error = describeError('read', 'the access rules', e);
            });
        return () => ac.abort();
    });
    const strip = $derived(
        `A2A gate · ConfigMap a2a-gate-rules · namespace ${list?.namespace || 'openagentix-gateway'}`,
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
        <Notice kind="error" title="Could not read the access rules"><p class="sm">{error}</p></Notice>
    {:else if !list}
        <div class="panel" aria-busy="true">
            <div class="bd stack">
                <span class="sr-only">Loading</span>
                <Skeleton class="w-[40%]" /><Skeleton class="w-full" /><Skeleton class="w-[70%]" />
            </div>
        </div>
    {:else if !list.configured}
        <div class="panel">
            <EmptyState icon="i-shield" title="The gate is off">
                <p>
                    No A2A gate runs, so there are no caller rules to show. Turn it on with <code
                        >governance.a2a.enabled</code
                    > in chart values. Until then agents are reached without a rule.
                </p>
            </EmptyState>
        </div>
    {:else if rows.length === 0}
        <div class="panel">
            <EmptyState icon="i-shield" title="The gate has no caller rule">
                <p>
                    The gate is on and its rules file names no caller, so nobody may call an agent through it. Add a
                    caller under <code>governance.a2a.callers</code> in chart values.
                </p>
            </EmptyState>
        </div>
    {:else}
        <section class="panel" aria-labelledby="ac-h">
            <div class="hd">
                <h2 id="ac-h">Who may call which agent</h2>
                <span class="sm t3">{rows.length} in total</span>
            </div>
            <div class="tw">
                <table>
                    <thead>
                        <tr
                            ><th>Caller</th><th>Set by</th><th>Signs in with</th><th>Agents</th><th>Methods</th><th
                                >User id</th
                            ></tr
                        >
                    </thead>
                    <tbody>
                        {#each rows as r (r.name)}
                            <tr>
                                <td>
                                    <button class="rowbtn mono" type="button" onclick={() => (picked = r)}
                                        >{r.name}</button
                                    >
                                </td>
                                <td
                                    >{#if r.source === 'chart'}<Tag>Chart</Tag>{:else}<Tag variant="accent">Values</Tag
                                        >{/if}</td
                                >
                                <td>{r.key ? 'Key' : 'Service account'}</td>
                                <td>
                                    <span class="tags"
                                        >{#each r.agents as a (a)}<Tag>{a}</Tag>{/each}</span
                                    >
                                </td>
                                <td>{methodWords(r.methods)}</td>
                                <td>{ruleWords(r.userIdRule)}</td>
                            </tr>
                        {/each}
                    </tbody>
                </table>
            </div>
        </section>
        <p class="sm t3">
            Keys, key hashes and user ids are never shown. The table says only what kind of user id rule a caller has.
        </p>
    {/if}
</section>

{#if picked}
    {@const r = picked}
    <SideSheet title={r.name} onclose={() => (picked = null)}>
        <dl class="kv sm">
            <dt>Set by</dt>
            <dd>
                {r.source === 'chart'
                    ? 'The chart, from the bridge, a schedule or a channel binding'
                    : 'governance.a2a.callers in chart values'}
            </dd>
            <dt>Signs in with</dt>
            <dd>{r.key ? 'A static key (never shown)' : 'A ServiceAccount token'}</dd>
            {#if r.serviceAccount}
                <dt>Service account</dt>
                <dd class="mono">{r.serviceAccount}</dd>
            {/if}
            <dt>Agents</dt>
            <dd>
                <span class="tags"
                    >{#each r.agents as a (a)}<Tag>{a}</Tag>{/each}</span
                >
            </dd>
            <dt>Methods</dt>
            <dd>
                <span class="tags"
                    >{#each r.methods as m (m)}<Tag>{m}</Tag>{/each}</span
                >
            </dd>
            <dt>User id</dt>
            <dd>{ruleWords(r.userIdRule)}</dd>
            <dt>Memory commands</dt>
            <dd>{r.memory ? 'May list and forget memories for its own user ids' : 'No'}</dd>
        </dl>
        <p class="sm t3 mt-3">
            Change a caller under <code>governance.a2a.callers</code> in chart values. A caller the chart derives follows
            its bridge, schedule or binding.
        </p>
    </SideSheet>
{/if}
