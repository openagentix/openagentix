<script lang="ts">
    // The metrics row of the Overview: spend, tokens and requests with sparklines, and spend per agent key. It renders ONLY
    // when the console API gave a summary; with none it renders nothing at all, so no zero or sample value is ever shown.
    import { headline, type MetricsSummary } from '$lib/metrics';
    import CostBars from './CostBars.svelte';
    import Sparkline from './Sparkline.svelte';

    interface Props {
        summary?: MetricsSummary | null;
    }
    let { summary = null }: Props = $props();
    const h = $derived(summary ? headline(summary) : null);
</script>

{#if summary && h}
    <div class="grid g3" role="group" aria-label="Metrics, from the gateway">
        <div class="tile">
            <div class="lbl">Spend today</div>
            <div class="val">{h.spendToday}</div>
            <Sparkline values={summary.series} label="Spend per step, last {summary.window}" />
            <div class="cmp">{h.spendNote}</div>
        </div>
        <div class="tile">
            <div class="lbl">Tokens</div>
            <div class="val">{h.tokensToday}</div>
            <div class="cmp">{h.tokensNote}</div>
        </div>
        <div class="tile">
            <div class="lbl">Model requests</div>
            <div class="val">{h.turns24h}</div>
            <div class="cmp">{h.turnsNote}</div>
        </div>
    </div>
    {#if summary.byUser.length}
        <section class="panel" aria-labelledby="ov-cost">
            <div class="hd">
                <h2 id="ov-cost">Spend per agent</h2>
                <span class="sm t3">last {summary.window} · key names are agents</span>
                <span class="acts"><a href="/costs">Open Costs</a></span>
            </div>
            <div class="bd"><CostBars users={summary.byUser.slice(0, 6)} /></div>
        </section>
    {/if}
{/if}
