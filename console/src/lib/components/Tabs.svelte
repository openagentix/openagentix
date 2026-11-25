<script lang="ts">
    // Page tabs: role="tablist", arrow keys move and activate, Home and End jump (UI-SPEC section 5).
    export interface TabDef {
        id: string;
        label: string;
    }
    interface Props {
        tabs: TabDef[];
        selected: string;
        label: string;
        prefix: string;
        onselect: (id: string) => void;
    }
    let { tabs, selected, label, prefix, onselect }: Props = $props();
    let list: HTMLElement | undefined = $state();
    function key(e: KeyboardEvent) {
        const i = tabs.findIndex((t) => t.id === selected);
        let n: number;
        if (e.key === 'ArrowRight') n = (i + 1) % tabs.length;
        else if (e.key === 'ArrowLeft') n = (i - 1 + tabs.length) % tabs.length;
        else if (e.key === 'Home') n = 0;
        else if (e.key === 'End') n = tabs.length - 1;
        else return;
        e.preventDefault();
        const t = tabs[n];
        if (!t) return;
        onselect(t.id);
        queueMicrotask(() => list?.querySelector<HTMLElement>(`#${prefix}-tab-${t.id}`)?.focus());
    }
</script>

<div class="tabs" role="tablist" aria-label={label} bind:this={list} onkeydown={key} tabindex="-1">
    {#each tabs as t (t.id)}
        <button
            type="button"
            class="tab"
            role="tab"
            id="{prefix}-tab-{t.id}"
            aria-selected={selected === t.id}
            aria-controls="{prefix}-panel-{t.id}"
            tabindex={selected === t.id ? 0 : -1}
            onclick={() => onselect(t.id)}>{t.label}</button
        >
    {/each}
</div>
