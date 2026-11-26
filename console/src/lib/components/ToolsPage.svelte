<script lang="ts">
    // Tools (UI-SPEC 6.7), read-only: the tool profiles of the catalog with their tool server, code mode and tool list,
    // whether the policy allows each, and which agents use it. No call counts: the console does not read the metrics.
    import { allows } from '$lib/draft';
    import { READONLY } from '$lib/planned';
    import { useAgents } from '$lib/useagents.svelte';
    import { usedBy } from '$lib/views';
    import Icon from './Icon.svelte';
    import Notice from './Notice.svelte';
    import PlatformGate from './PlatformGate.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import Tag from './Tag.svelte';
    import UsedBy from './UsedBy.svelte';

    const c = READONLY['tools']!;
    const src = useAgents();
    $effect(() => {
        void src.load();
    });
    let picked = $state('');
    const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;
</script>

<PlatformGate title={c.title} strip={c.strip} noticeTitle={c.noticeTitle} notice={c.notice}>
    {#snippet children(p)}
        {@const sel = p.profiles.find((x) => x.name === picked) ?? p.profiles[0]}
        {#if src.error}<Notice kind="error" title="Could not read the agents"><p class="sm">{src.error}</p></Notice
            >{/if}
        <div class="ld">
            <div class="stack">
                {#if p.profiles.length === 0}
                    <div class="panel">
                        <div class="bd"><p class="t2">The platform catalog lists no tool profile.</p></div>
                    </div>
                {:else}
                    <h2 class="sm t3 upper">Tool profiles</h2>
                    <div class="grid g2 cards">
                        {#each p.profiles as pr (pr.name)}
                            {@const ok = allows(p.policy.allowedProfiles, pr.name)}
                            {@const users = usedBy(src.items, (a) => a.toolProfile === pr.name)}
                            <button
                                class="card"
                                type="button"
                                aria-pressed={sel?.name === pr.name}
                                onclick={() => (picked = pr.name)}
                            >
                                <div class="row1">
                                    <span class="ico"><Icon name="i-tool" /></span><b class="mono">{pr.name}</b>
                                    <StatusBadge
                                        state={ok ? 'ready' : 'paused'}
                                        word={ok ? 'Allowed' : 'Not allowed'}
                                    />
                                </div>
                                <p class="sm t2"><code>{pr.toolServer}</code></p>
                                <div class="meta">
                                    <span>{plural(pr.tools.length, 'tool')}</span>
                                    {#if pr.codeMode}<span>code mode</span>{/if}
                                    <span>{plural(users.length, 'agent')}</span>
                                </div>
                            </button>
                        {/each}
                    </div>
                {/if}
                <div class="panel">
                    <div class="hd"><h2>Tool adapter</h2></div>
                    <div class="bd">
                        <dl class="kv sm">
                            <dt>Tools</dt>
                            <dd><code>{p.adapters.tools}</code> in namespace <code>{p.namespaces.tools}</code></dd>
                        </dl>
                        <p class="sm t3 mt-3">
                            The shared server filters on the client side only, so built agents cannot use it: they use a
                            tool profile.
                        </p>
                    </div>
                </div>
                {#if p.knowledge.available || p.notify.available}
                    <div class="panel">
                        <div class="hd">
                            <h2>Tools added by a switch</h2>
                            <span class="sm t3">on top of the profile</span>
                        </div>
                        <div class="bd">
                            <dl class="kv sm">
                                {#if p.knowledge.available}
                                    <dt>Knowledge</dt>
                                    <dd>
                                        <span class="tags"
                                            >{#each p.knowledge.tools as t (t)}<Tag>{t}</Tag>{/each}</span
                                        >
                                    </dd>
                                {/if}
                                {#if p.notify.available}
                                    <dt>Notify</dt>
                                    <dd>
                                        <span class="tags"
                                            >{#each p.notify.tools as t (t)}<Tag>{t}</Tag>{/each}</span
                                        >
                                    </dd>
                                {/if}
                            </dl>
                        </div>
                    </div>
                {/if}
            </div>
            <aside class="panel detail" aria-labelledby="td-title">
                {#if sel}
                    {@const ok = allows(p.policy.allowedProfiles, sel.name)}
                    <div class="hd">
                        <h2 id="td-title" class="mono-title">{sel.name}</h2>
                        <StatusBadge state={ok ? 'ready' : 'paused'} word={ok ? 'Allowed' : 'Not allowed'} />
                    </div>
                    <div class="bd">
                        <dl class="kv sm">
                            <dt>Tool server</dt>
                            <dd><code>{sel.toolServer}</code></dd>
                            <dt>Code mode</dt>
                            <dd>{sel.codeMode ? 'on: the agent runs tools from a script' : 'off'}</dd>
                            <dt>Policy</dt>
                            <dd>
                                {#if ok}listed in <code>allowedProfiles</code>{:else}not in the policy
                                    <code>allowedProfiles</code>: a definition that names it is refused{/if}
                            </dd>
                            <dt>Used by</dt>
                            <dd><UsedBy names={usedBy(src.items, (a) => a.toolProfile === sel.name)} /></dd>
                        </dl>
                        <div>
                            <h3>Tools the profile offers</h3>
                            {#if sel.tools.length}
                                <ul class="toollist">
                                    {#each sel.tools as t (t)}<li><code>{t}</code></li>{/each}
                                </ul>
                            {:else}
                                <p class="sm t3 mt-1">The profile lists no tool.</p>
                            {/if}
                        </div>
                    </div>
                {:else}
                    <div class="hd"><h2 id="td-title">Tool profile</h2></div>
                    <div class="bd"><p class="sm t3">Select a profile to see its tools and who uses it.</p></div>
                {/if}
            </aside>
        </div>
    {/snippet}
</PlatformGate>
