<script lang="ts">
    // The frame of a read-only page: the header, the read-only notice, and the page body once the platform summary is here.
    import type { Snippet } from 'svelte';
    import { ctx } from '$lib/context.svelte';
    import { segments } from '$lib/planned';
    import type { Platform } from '$lib/types';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import Skeleton from './Skeleton.svelte';

    interface Props {
        title: string;
        strip: string;
        noticeTitle?: string;
        notice?: string;
        /** `ro` for a read-only page, `info` for a page whose notice is plain information. */
        noticeKind?: 'ro' | 'info';
        actions?: Snippet;
        children: Snippet<[Platform]>;
    }
    let { title, strip, noticeTitle, notice, noticeKind = 'ro', actions, children }: Props = $props();
    const platform = $derived(ctx.platform);
</script>

<svelte:head><title>{title} · OpenAgentix console</title></svelte:head>

<section class="view max-form">
    <PageHeader {title} {strip} {actions} />
    {#if notice}
        <Notice kind={noticeKind} title={noticeTitle}>
            <p class="sm">
                {#each segments(notice) as seg, i (i)}{#if seg.code}<code>{seg.text}</code>{:else}{seg.text}{/if}{/each}
            </p>
        </Notice>
    {/if}
    {#if platform}
        {@render children(platform)}
    {:else if ctx.platformError}
        <Notice kind="error" title="Could not read the platform catalog and policy">
            <p class="sm">{ctx.platformError}</p>
        </Notice>
    {:else}
        <div class="panel" aria-busy="true">
            <div class="bd stack">
                <span class="sr-only">Loading</span>
                <Skeleton class="w-[40%]" /><Skeleton class="w-full" /><Skeleton class="w-[70%]" />
            </div>
        </div>
    {/if}
</section>
