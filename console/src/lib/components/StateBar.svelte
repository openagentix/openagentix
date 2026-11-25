<script lang="ts">
    // Agents by state as one segmented bar with a legend (colour, word and count): inline SVG, status tokens, 2 px gaps.
    // The legend carries the meaning, so the colour is never alone. The bar has a text alternative.
    import type { StateCounts } from '$lib/views';

    interface Props {
        counts: StateCounts;
    }
    let { counts }: Props = $props();

    const KEYS = [
        { key: 'ready', word: 'Ready' },
        { key: 'pending', word: 'Pending' },
        { key: 'refused', word: 'Refused' },
        { key: 'error', word: 'Failed' },
        { key: 'paused', word: 'Paused' },
    ] as const;

    const parts = $derived(KEYS.map((k) => ({ ...k, n: counts[k.key] })).filter((p) => p.n > 0));
    const total = $derived(Math.max(counts.total, 1));
    const bars = $derived.by(() => {
        let x = 0;
        return parts.map((p) => {
            const w = (p.n / total) * 100;
            const r = { ...p, x, w };
            x += w;
            return r;
        });
    });
    const alt = $derived(
        `${counts.total} agents: ${KEYS.map((k) => `${counts[k.key]} ${k.word.toLowerCase()}`).join(', ')}; ${counts.chart} chart-managed`,
    );
</script>

<div class="statebar">
    <svg viewBox="0 0 100 10" preserveAspectRatio="none" role="img" aria-label={alt} class="sb-svg">
        <rect x="0" y="0" width="100" height="10" rx="2" class="sb-empty" />
        {#each bars as b (b.key)}
            <rect x={b.x} y="0" width={Math.max(b.w - 0.8, 0.4)} height="10" rx="1.5" class="seg-{b.key}" />
        {/each}
    </svg>
    <ul class="legend-row">
        {#each KEYS as k (k.key)}
            <li><span class="dot d-{k.key}" aria-hidden="true"></span>{counts[k.key]} {k.word.toLowerCase()}</li>
        {/each}
        <li><span class="dot d-chart" aria-hidden="true"></span>{counts.chart} chart-managed</li>
    </ul>
</div>
