<script lang="ts">
    // Traces (UI-SPEC 6.13), read-only: recent agent turns and, for one turn, a waterfall with a span detail panel. Prompts,
    // answers and tool arguments are never shown: the API passes on an allowlist of attributes only.
    import { page } from '$app/state';
    import { api, ApiError } from '$lib/api';
    import { ctx } from '$lib/context.svelte';
    import { PLANNED } from '$lib/planned';
    import { formatTime } from '$lib/status';
    import { formatMs, layout, outcomeState, type TraceDetail, type Turn } from '$lib/traces';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import PlannedPage from './PlannedPage.svelte';
    import StatusBadge from './StatusBadge.svelte';

    const available = $derived(ctx.platform?.traces?.available === true);
    let turns = $state<Turn[] | null>(null);
    let error = $state('');
    let detail = $state<TraceDetail | null>(null);
    let detailError = $state('');
    let spanId = $state('');
    let picked = $state('');

    const msg = (e: unknown) =>
        e instanceof ApiError && e.code === 'traces_unavailable'
            ? e.message
            : 'Traces are not available: the console could not read them.';

    $effect(() => {
        if (!available) return;
        api.traces().then(
            (r) => {
                turns = r.items;
                error = '';
            },
            (e) => {
                error = msg(e);
            },
        );
    });

    const wanted = $derived(picked || page.url.searchParams.get('trace') || '');
    $effect(() => {
        const id = wanted;
        if (!available || !id) {
            detail = null;
            return;
        }
        api.trace(id).then(
            (d) => {
                detail = d;
                detailError = '';
                spanId = d.spans[0]?.id ?? '';
            },
            (e) => {
                detail = null;
                detailError = e instanceof ApiError && e.status === 400 ? e.message : msg(e);
            },
        );
    });

    const rows = $derived(detail ? layout(detail) : []);
    const sel = $derived(rows.find((r) => r.span.id === spanId)?.span ?? rows[0]?.span);
</script>

<svelte:head><title>Traces · OpenAgentix console</title></svelte:head>

{#if !available}
    <PlannedPage content={PLANNED['traces']!} />
{:else}
    <section class="view">
        <PageHeader title="Traces" strip="observability adapter · bundled Jaeger · last 2,000 traces in memory" />
        <Notice kind="ro" title="Prompts and answers are not stored">
            <p class="sm">
                Content capture is off, so a span shows names, durations, models and token counts only. The bundled
                trace store keeps the last 2,000 traces in memory and loses them on a restart.
            </p>
        </Notice>
        {#if error}
            <Notice kind="error" title="Could not read the traces"><p class="sm">{error}</p></Notice>
        {/if}
        <section class="panel" aria-labelledby="tr-recent">
            <div class="hd">
                <h2 id="tr-recent">Recent turns</h2>
                <span class="sm t3">last 6 hours</span>
            </div>
            {#if turns === null && !error}
                <div class="bd"><p class="t3">Reading the traces.</p></div>
            {:else if turns && turns.length === 0}
                <div class="bd"><p class="t2">No agent turn in the last 6 hours.</p></div>
            {:else if turns}
                <div class="tw">
                    <table>
                        <thead>
                            <tr>
                                <th>Time</th><th>Agent</th><th>Outcome</th><th class="r">Model calls</th><th class="r"
                                    >Duration</th
                                ><th class="r">Tokens in / out</th><th></th>
                            </tr>
                        </thead>
                        <tbody>
                            {#each turns as t (t.traceId)}
                                <tr data-trace={t.traceId} class={wanted === t.traceId ? 'sel' : ''}>
                                    <td class="sm t3">{formatTime(t.start)}</td>
                                    <td class="mono">{t.agent}</td>
                                    <td
                                        ><StatusBadge
                                            state={outcomeState(t.outcome).state}
                                            word={outcomeState(t.outcome).word}
                                        /></td
                                    >
                                    <td class="r num">{t.modelCalls}</td>
                                    <td class="r num">{formatMs(t.durationMs)}</td>
                                    <td class="r num">{t.tokensIn} / {t.tokensOut}</td>
                                    <td class="r">
                                        <button class="linkbtn" type="button" onclick={() => (picked = t.traceId)}
                                            >Open trace<span class="sr-only"> {t.traceId}</span></button
                                        >
                                    </td>
                                </tr>
                            {/each}
                        </tbody>
                    </table>
                </div>
            {/if}
        </section>

        {#if detailError}
            <Notice kind="error" title="Could not read the trace"><p class="sm">{detailError}</p></Notice>
        {/if}
        {#if detail}
            <div class="ld">
                <section class="panel" aria-labelledby="tr-wf">
                    <div class="hd">
                        <h2 id="tr-wf">Turn <code>{detail.traceId}</code></h2>
                        <span class="sm t3">{formatMs(detail.durationMs)} · {detail.spans.length} spans</span>
                    </div>
                    <ul class="waterfall" aria-label="Spans of the turn, in start order">
                        {#each rows as r (r.span.id)}
                            <li>
                                <button
                                    type="button"
                                    class="wf {r.span.id === sel?.id ? 'on' : ''} {r.span.error ? 'err' : ''}"
                                    aria-pressed={r.span.id === sel?.id}
                                    onclick={() => (spanId = r.span.id)}
                                >
                                    <span class="wf-name d{Math.min(r.depth, 6)}"
                                        ><span class="mono">{r.span.name}</span><span class="sm t3"
                                            >{r.span.service}</span
                                        ></span
                                    >
                                    <svg
                                        viewBox="0 0 100 8"
                                        preserveAspectRatio="none"
                                        class="wf-bar"
                                        aria-hidden="true"
                                    >
                                        <rect x="0" y="0" width="100" height="8" class="wf-track" />
                                        <rect x={r.left} y="1" width={r.width} height="6" rx="1.5" class="wf-fill" />
                                    </svg>
                                    <span class="num sm wf-dur"
                                        >{formatMs(r.span.durationMs)}<span class="sr-only"
                                            >, starts at {formatMs(r.span.offsetMs)}</span
                                        ></span
                                    >
                                </button>
                            </li>
                        {/each}
                    </ul>
                </section>
                <aside class="panel detail" aria-labelledby="tr-span">
                    <div class="hd"><h2 id="tr-span" class="mono-title">{sel?.name ?? 'Span'}</h2></div>
                    <div class="bd">
                        {#if sel}
                            <dl class="kv sm">
                                <dt>Service</dt>
                                <dd><code>{sel.service}</code></dd>
                                <dt>Starts at</dt>
                                <dd>{formatMs(sel.offsetMs)}</dd>
                                <dt>Lasts</dt>
                                <dd>{formatMs(sel.durationMs)}</dd>
                                {#each Object.entries(sel.attrs) as [k, v] (k)}
                                    <dt><code>{k}</code></dt>
                                    <dd><code>{v}</code></dd>
                                {/each}
                            </dl>
                            <p class="sm t3">
                                Only attributes on the console's allowlist are shown. Arguments and results are never
                                shown.
                            </p>
                        {/if}
                    </div>
                </aside>
            </div>
        {/if}
    </section>
{/if}
