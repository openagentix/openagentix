<script lang="ts">
    // The agents that use something: names in mono, each a link to its builder, or one plain sentence when none does.
    interface Props {
        names: string[];
        none?: string;
    }
    let { names, none = 'No agent uses it yet.' }: Props = $props();
</script>

{#if names.length}
    <span class="tags"
        >{#each names as n (n)}<a class="tag" href="/agents/{encodeURIComponent(n)}">{n}</a>{/each}</span
    >
{:else}
    <span class="t3">{none}</span>
{/if}
