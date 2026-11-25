<script lang="ts">
    // The slot row for spend, tokens and turns. It renders ONLY when the console API says metrics are available and gives
    // the numbers; with no summary it renders nothing at all, so no zero or sample value is ever shown.
    import type { MetricsHeadline } from '$lib/types';

    interface Props {
        summary?: MetricsHeadline | null;
    }
    let { summary = null }: Props = $props();
</script>

{#if summary}
    <div class="grid g3" role="group" aria-label="Metrics, from the gateway">
        <div class="tile">
            <div class="lbl">Spend today</div>
            <div class="val">{summary.spendToday}</div>
            <div class="cmp">{summary.spendNote}</div>
        </div>
        <div class="tile">
            <div class="lbl">Tokens today</div>
            <div class="val">{summary.tokensToday}</div>
            <div class="cmp">{summary.tokensNote}</div>
        </div>
        <div class="tile">
            <div class="lbl">Turns, last 24 h</div>
            <div class="val">{summary.turns24h}</div>
            <div class="cmp">{summary.turnsNote}</div>
        </div>
    </div>
{/if}
