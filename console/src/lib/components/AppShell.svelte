<script lang="ts">
    import type { Snippet } from 'svelte';
    import { goto } from '$app/navigation';
    import { page } from '$app/state';
    import { trapFocus } from '$lib/actions';
    import { ctx } from '$lib/context.svelte';
    import { activeId, breadcrumb, GO_KEYS, isTypingTarget, MARKS, NAV, SETTINGS, type NavItem } from '$lib/nav';
    import { contextLine } from '$lib/views';
    import { shortcutPref, sidebarPref, theme } from '$lib/theme.svelte';
    import GoTo from './GoTo.svelte';
    import Icon from './Icon.svelte';
    import IconButton from './IconButton.svelte';

    let { children }: { children: Snippet } = $props();

    let collapsed = $state(sidebarPref.collapsed);
    let drawer = $state(false);
    let goToOpen = $state(false);
    let pendingG = $state(false);
    let pendingTimer: ReturnType<typeof setTimeout> | undefined;
    let nav: HTMLElement | undefined = $state();

    const path = $derived(page.url.pathname);
    const current = $derived(activeId(path));
    const crumb = $derived(breadcrumb(path));
    const session = $derived(ctx.session);
    const ctxLine = $derived(contextLine(session));

    function toggleCollapse() {
        collapsed = !collapsed;
        sidebarPref.set(collapsed);
    }

    // the mobile drawer: focus stays inside, Escape and a selection close it
    $effect(() => {
        if (!drawer || !nav) return;
        const t = trapFocus(nav, { initial: 'a', onescape: () => (drawer = false) });
        return () => t.destroy();
    });
    $effect(() => {
        void path;
        drawer = false;
    });

    function onkey(e: KeyboardEvent) {
        if (e.ctrlKey || e.metaKey) {
            if (e.key.toLowerCase() === 'k') {
                e.preventDefault();
                goToOpen = true;
            }
            return;
        }
        if (e.altKey || isTypingTarget(e.target) || goToOpen) return;
        if (!shortcutPref.on) return;
        if (pendingG) {
            pendingG = false;
            clearTimeout(pendingTimer);
            const dest = GO_KEYS[e.key.toLowerCase()];
            if (dest) {
                e.preventDefault();
                void goto(dest);
            }
            return;
        }
        if (e.key === 'g') {
            pendingG = true;
            clearTimeout(pendingTimer);
            pendingTimer = setTimeout(() => (pendingG = false), 1500);
        } else if (e.key === '/') {
            e.preventDefault();
            goToOpen = true;
        } else if (e.key === '[') {
            toggleCollapse();
        }
    }

    function isCurrent(i: NavItem): boolean {
        return current === i.id;
    }
</script>

<svelte:window onkeydown={onkey} />

<a class="skip" href="#content">Skip to content</a>
<div class="app {collapsed ? 'collapsed' : ''} {drawer ? 'drawer' : ''}" id="app">
    {#if drawer}<div
            class="sidebar-scrim"
            data-overlay-part=""
            role="presentation"
            onclick={() => (drawer = false)}
        ></div>{/if}
    <nav class="sb" aria-label="Main" id="sidebar" bind:this={nav} aria-hidden={undefined}>
        <div class="brand">
            <div class="mark" aria-hidden="true">
                <svg viewBox="0 0 14 14"
                    ><circle cx="3" cy="7" r="1.8" /><circle cx="11" cy="7" r="1.8" /><path
                        d="M4.8 7h4.4M7 4.5v5"
                    /></svg
                >
            </div>
            <div class="word"><span>Open</span><b>Agentix</b></div>
        </div>
        {#if ctxLine}<div class="ctx" title="Cluster context and agent namespace: {ctxLine}">{ctxLine}</div>{/if}
        {#each NAV as g (g.label ?? 'top')}
            {#if g.label}<div class="grp">{g.label}</div>{/if}
            <div class="nav">
                {#each g.items as i (i.id)}
                    <a
                        class="ni"
                        href={i.href}
                        aria-current={isCurrent(i) &&
                        (!i.sub || path === i.href || !path.startsWith('/agents/playground') || i.id !== 'agents')
                            ? 'page'
                            : undefined}
                        aria-label={collapsed ? i.label : undefined}
                        title={collapsed ? i.label : undefined}
                    >
                        <Icon name={i.icon} /><span>{i.label}</span>
                        {#if i.mark}<span
                                class="mk mk-{i.mark}"
                                title={MARKS[i.mark].label}
                                role="img"
                                aria-label={MARKS[i.mark].label}><Icon name={MARKS[i.mark].icon} size={12} /></span
                            >{/if}
                    </a>
                    {#if i.sub && isCurrent(i)}
                        <div class="sub">
                            {#each i.sub as s (s.href)}
                                <a
                                    href={s.href}
                                    class={path === s.href ||
                                    (s.href === '/agents' &&
                                        path.startsWith('/agents/') &&
                                        path !== '/agents/playground')
                                        ? 'on'
                                        : ''}
                                    aria-current={path === s.href ? 'page' : undefined}>{s.label}</a
                                >
                            {/each}
                        </div>
                    {/if}
                {/each}
            </div>
        {/each}
        <div class="sb-foot">
            <a
                class="ni"
                href={SETTINGS.href}
                aria-current={current === 'settings' ? 'page' : undefined}
                aria-label={collapsed ? 'Settings' : undefined}
                title={collapsed ? 'Settings' : undefined}><Icon name={SETTINGS.icon} /><span>Settings</span></a
            >
            <button
                class="ni collapse-btn"
                type="button"
                aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
                aria-keyshortcuts="["
                onclick={toggleCollapse}><Icon name="i-side" /><span>Collapse</span></button
            >
        </div>
    </nav>

    <div class="main">
        <header class="top">
            <button
                class="ib menu-btn"
                type="button"
                aria-label="Open navigation"
                aria-expanded={drawer}
                aria-controls="sidebar"
                onclick={() => (drawer = true)}><Icon name="i-menu" /></button
            >
            <nav class="crumb" aria-label="Breadcrumb">
                {#each crumb as c, i (i)}
                    {#if i < crumb.length - 1}
                        <a
                            href={i === 0 ? NAV.flatMap((g) => g.items).find((x) => x.label === c)?.href : undefined}
                            class="t3">{c}</a
                        ><Icon name="i-chev" size={12} />
                    {:else}
                        <b
                            aria-current="page"
                            class={crumb.length > 1 &&
                            path.startsWith('/agents/') &&
                            c !== 'Playground' &&
                            c !== 'New agent'
                                ? 'mono'
                                : ''}>{c}</b
                        >
                    {/if}
                {/each}
            </nav>
            <button
                class="search"
                type="button"
                aria-label="Search agents and pages"
                aria-keyshortcuts="/"
                onclick={() => (goToOpen = true)}
            >
                <Icon name="i-search" /><span>Search agents, tools, pages</span><kbd>/</kbd>
            </button>
            {#if session?.demo}<span class="demo" title="The platform catalog marks this install as a demo"
                    >Demo data</span
                >{/if}
            <IconButton
                icon="i-theme"
                label={theme.dark ? 'Switch to light theme' : 'Switch to dark theme'}
                onclick={() => theme.toggle()}
                id="theme-toggle"
            />
        </header>

        <main class="content" id="content" tabindex="-1">
            {@render children()}
        </main>
        <footer class="foot">
            <span><strong>OpenAgentix console</strong> {session?.version ?? ''}</span>
            <span class="legend"
                ><Icon name={MARKS.readonly.icon} size={12} class="align-[-2px]" /> {MARKS.readonly.legend}</span
            >
            <span class="legend"
                ><Icon name={MARKS.nodata.icon} size={12} class="align-[-2px]" /> {MARKS.nodata.legend}</span
            >
        </footer>
    </div>
</div>
{#if goToOpen}<GoTo onclose={() => (goToOpen = false)} />{/if}
