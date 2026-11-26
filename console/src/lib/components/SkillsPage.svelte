<script lang="ts">
    // Skills (UI-SPEC 6.5), read-only: the skills of the catalog with their pinned reference, whether the policy allows each,
    // and which agents use it. The digest is shortened on the card; the full reference is shown and copied from the panel.
    import { copyText } from '$lib/actions';
    import { allows } from '$lib/draft';
    import { READONLY } from '$lib/planned';
    import { toasts } from '$lib/toast.svelte';
    import { useAgents } from '$lib/useagents.svelte';
    import { shortRef, usedBy } from '$lib/views';
    import Icon from './Icon.svelte';
    import IconButton from './IconButton.svelte';
    import Notice from './Notice.svelte';
    import PlatformGate from './PlatformGate.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import UsedBy from './UsedBy.svelte';

    const c = READONLY['skills']!;
    const src = useAgents();
    $effect(() => {
        void src.load();
    });
    let picked = $state('');
    const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;

    async function copy(ref: string) {
        if (await copyText(ref)) toasts.success('Copied');
        else toasts.error('Could not copy: the browser refused clipboard access. Select the text and copy it by hand.');
    }
</script>

<PlatformGate title={c.title} strip={c.strip} noticeTitle={c.noticeTitle} notice={c.notice}>
    {#snippet children(p)}
        {@const sel = p.skills.find((s) => s.name === picked) ?? p.skills[0]}
        {#if src.error}<Notice kind="error" title="Could not read the agents"><p class="sm">{src.error}</p></Notice
            >{/if}
        {#if p.skills.length === 0}
            <div class="panel"><div class="bd"><p class="t2">The platform catalog lists no skill.</p></div></div>
        {:else}
            <div class="ld">
                <div class="grid g2 cards">
                    {#each p.skills as s (s.name)}
                        {@const ok = allows(p.policy.allowedSkills, s.name)}
                        {@const users = usedBy(src.items, (a) => a.skills.includes(s.name))}
                        <button
                            class="card"
                            type="button"
                            aria-pressed={sel?.name === s.name}
                            onclick={() => (picked = s.name)}
                        >
                            <div class="row1">
                                <span class="ico"><Icon name="i-skill" /></span><b class="mono">{s.name}</b>
                                <StatusBadge state={ok ? 'ready' : 'paused'} word={ok ? 'Allowed' : 'Not allowed'} />
                            </div>
                            <p class="sm t2 ref"><code>{shortRef(s.ref)}</code></p>
                            <div class="meta"><span>{plural(users.length, 'agent')}</span></div>
                        </button>
                    {/each}
                </div>
                <aside class="panel detail" aria-labelledby="sk-title">
                    {#if sel}
                        {@const ok = allows(p.policy.allowedSkills, sel.name)}
                        <div class="hd">
                            <h2 id="sk-title" class="mono-title">{sel.name}</h2>
                            <StatusBadge state={ok ? 'ready' : 'paused'} word={ok ? 'Allowed' : 'Not allowed'} />
                        </div>
                        <div class="bd">
                            <dl class="kv sm">
                                <dt>Reference</dt>
                                <dd>
                                    <code>{sel.ref}</code>
                                    <IconButton
                                        icon="i-copy"
                                        label="Copy the full reference"
                                        onclick={() => copy(sel.ref)}
                                    />
                                </dd>
                                <dt>Policy</dt>
                                <dd>
                                    {#if ok}listed in <code>allowedSkills</code>{:else}not in the policy
                                        <code>allowedSkills</code>: a definition that names it is refused{/if}
                                </dd>
                                <dt>Used by</dt>
                                <dd><UsedBy names={usedBy(src.items, (a) => a.skills.includes(sel.name))} /></dd>
                            </dl>
                            <p class="sm t3">
                                Versions, publishers and <code>SKILL.md</code> appear here once the organisation skill registry
                                exists.
                            </p>
                        </div>
                    {/if}
                </aside>
            </div>
        {/if}
    {/snippet}
</PlatformGate>
