<script lang="ts">
    // A 2 px line with an end dot, in the first chart colour (inline SVG, no axes). The text alternative states the range.
    import { sparkPath, usd } from '$lib/metrics';

    interface Props {
        values: number[];
        label: string;
    }
    let { values, label }: Props = $props();
    const W = 120;
    const H = 28;
    const p = $derived(sparkPath(values, W, H - 6));
    const alt = $derived(
        values.length
            ? `${label}: ${values.length} points, from ${usd(Math.min(...values))} to ${usd(Math.max(...values))}`
            : `${label}: no points`,
    );
</script>

{#if values.length}
    <svg viewBox="0 0 {W + 6} {H}" class="spark" role="img" aria-label={alt}>
        <g transform="translate(3 3)">
            <path d={p.line} class="spark-line" />
            <circle cx={p.last.x} cy={p.last.y} r="3" class="spark-dot" />
        </g>
    </svg>
{/if}
