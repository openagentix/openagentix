<script lang="ts">
    // Costs (UI-SPEC 6.14), read-only, from GET /api/v1/metrics/summary. Without a metrics store the page says which source
    // is missing and shows no number.
    import { ctx } from '$lib/context.svelte';
    import { compact, usd } from '$lib/metrics';
    import { useMetrics } from '$lib/usemetrics.svelte';
    import CostBars from './CostBars.svelte';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import Segmented from './Segmented.svelte';
    import Sparkline from './Sparkline.svelte';

    const m = useMetrics();
    let win = $state<'24h' | '7d'>('24h');
    const available = $derived(ctx.platform?.metrics?.available === true);
    $effect(() => {
        if (available) void m.load(win);
    });
    const s = $derived(m.summary);
    const total = $derived(s?.byUser.reduce((a, u) => a + u.costUsd, 0) ?? 0);
</script>

<svelte:head><title>Costs · OpenAgentix console</title></svelte:head>

<section class="view max-form">
    <PageHeader title="Costs" strip="gateway metrics · agentgateway_gen_ai_client_cost_usd_total · metrics store" />

    {#if !available}
        <Notice kind="ro" title="No metrics store is configured">
            <p class="sm">
                The console reads costs from a Prometheus-compatible store. Turn on <code>observability.enabled</code>
                and
                <code>observability.bundled.enabled</code> in chart values, or set <code>console.metrics.url</code>.
                Until then this page shows no number.
            </p>
        </Notice>
    {:else}
        <div class="toolbar">
            <Segmented
                label="Window"
                value={win}
                options={[
                    { id: '24h', label: 'Last 24 h' },
                    { id: '7d', label: 'Last 7 d' },
                ]}
                onselect={(id) => (win = id as '24h' | '7d')}
            />
            <span class="sm t3">The bundled store keeps 7 days of metrics.</span>
        </div>
        {#if m.error}
            <Notice kind="error" title="Could not read the metrics"><p class="sm">{m.error}</p></Notice>
        {:else if s}
            <div class="grid g4" role="group" aria-label="Totals">
                <div class="tile">
                    <div class="lbl">Spend, last {s.window}</div>
                    <div class="val">{usd(s.spendUsd)}</div>
                    <Sparkline values={s.series} label="Spend per step, last {s.window}" />
                    <div class="cmp">gateway price catalog</div>
                </div>
                <div class="tile">
                    <div class="lbl">Tokens in</div>
                    <div class="val">{compact(s.tokensIn)}</div>
                    <div class="cmp">{compact(s.tokensOut)} out</div>
                </div>
                <div class="tile">
                    <div class="lbl">Cache read share</div>
                    <div class="val">
                        {s.cacheReadShare === undefined ? 'n/a' : `${Math.round(s.cacheReadShare * 100)}%`}
                    </div>
                    <div class="cmp">
                        {s.cacheReadShare === undefined
                            ? 'the gateway reports no cache-read tokens'
                            : 'of input tokens'}
                    </div>
                </div>
                <div class="tile">
                    <div class="lbl">Model requests</div>
                    <div class="val">{compact(s.requests)}</div>
                    <div class="cmp">counted by the gateway</div>
                </div>
            </div>
            <section class="panel" aria-labelledby="co-by">
                <div class="hd">
                    <h2 id="co-by">Spend per agent key</h2>
                    <span class="sm t3">user_id is an agent's gateway key, never a person</span>
                </div>
                {#if s.byUser.length === 0}
                    <div class="bd"><p class="t2">No spend in this window.</p></div>
                {:else}
                    <div class="bd"><CostBars users={s.byUser} /></div>
                    <div class="tw">
                        <table>
                            <caption class="sr-only">Cost and tokens per gateway user</caption>
                            <thead>
                                <tr
                                    ><th>Gateway user</th><th class="r">Cost</th><th class="r">Share</th><th class="r"
                                        >Tokens in</th
                                    ><th class="r">Tokens out</th><th class="r">Cache read</th></tr
                                >
                            </thead>
                            <tbody>
                                {#each s.byUser as u (u.user)}
                                    <tr>
                                        <td class="mono">{u.user}</td>
                                        <td class="r num">{usd(u.costUsd)}</td>
                                        <td class="r num"
                                            >{total > 0 ? `${Math.round((u.costUsd / total) * 100)}%` : '0%'}</td
                                        >
                                        <td class="r num">{compact(u.tokensIn)}</td>
                                        <td class="r num">{compact(u.tokensOut)}</td>
                                        <td class="r num">{compact(u.tokensCacheRead)}</td>
                                    </tr>
                                {/each}
                            </tbody>
                        </table>
                    </div>
                {/if}
            </section>
            <p class="sm t3">
                Cost is the gateway's own catalog price; a model missing from the catalog has no cost. For a series
                younger than the window the first scrape counts as an increase from zero, so the first hour can read
                high. USD budgets come with the <code>Budget</code> kind.
            </p>
        {:else}
            <div class="panel" aria-busy="true">
                <div class="bd">
                    <span class="sr-only">Loading</span>
                    <p class="t3">Reading the metrics.</p>
                </div>
            </div>
        {/if}
    {/if}
</section>
