<script lang="ts">
    // Models (UI-SPEC 6.6), read-only: the gateway models of the catalog, whether the policy allows each, and who uses it.
    // Providers, upstream names, credentials, prices and spend have no source in the console API; the page does not show them.
    import { allows } from '$lib/draft';
    import { READONLY } from '$lib/planned';
    import { useAgents } from '$lib/useagents.svelte';
    import { usedBy } from '$lib/views';
    import Icon from './Icon.svelte';
    import Notice from './Notice.svelte';
    import PlatformGate from './PlatformGate.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import UsedBy from './UsedBy.svelte';

    const c = READONLY['models']!;
    const src = useAgents();
    $effect(() => {
        void src.load();
    });
    let picked = $state('');
    const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;
</script>

<PlatformGate title={c.title} strip={c.strip} noticeTitle={c.noticeTitle} notice={c.notice}>
    {#snippet children(p)}
        {@const sel = p.models.includes(picked) ? picked : (p.models[0] ?? '')}
        {#if src.error}<Notice kind="error" title="Could not read the agents"><p class="sm">{src.error}</p></Notice
            >{/if}
        {#if p.models.length === 0}
            <div class="panel">
                <div class="bd"><p class="t2">The platform catalog lists no gateway model.</p></div>
            </div>
        {:else}
            <div class="ld">
                <div class="stack">
                    <div class="grid g3 cards">
                        {#each p.models as m (m)}
                            {@const ok = allows(p.policy.allowedModels, m)}
                            {@const users = usedBy(src.items, (a) => a.model === m)}
                            <button class="card" type="button" aria-pressed={sel === m} onclick={() => (picked = m)}>
                                <div class="row1">
                                    <span class="ico"><Icon name="i-model" /></span><b class="mono">{m}</b>
                                    <StatusBadge
                                        state={ok ? 'ready' : 'paused'}
                                        word={ok ? 'Allowed' : 'Not allowed'}
                                    />
                                </div>
                                <div class="meta"><span>{plural(users.length, 'agent')}</span></div>
                            </button>
                        {/each}
                    </div>
                    <div class="panel">
                        <div class="hd">
                            <h2>Gateway</h2>
                            <span class="sm t3">where every model call goes</span>
                        </div>
                        <div class="bd">
                            <dl class="kv sm">
                                <dt>Model gateway</dt>
                                <dd><code>{p.adapters.modelGateway}</code></dd>
                                <dt>Base URL</dt>
                                <dd><code>{p.gatewayBaseUrl}</code></dd>
                                <dt>Namespace</dt>
                                <dd><code>{p.namespaces.gateway}</code></dd>
                            </dl>
                            <p class="sm t3 mt-3">
                                Providers, upstream model names, credentials and prices are not read by the console in
                                this release, so they are not shown.
                            </p>
                        </div>
                    </div>
                </div>
                <aside class="panel detail" aria-labelledby="md-title">
                    <div class="hd">
                        <h2 id="md-title" class="mono-title">{sel}</h2>
                        <StatusBadge
                            state={allows(p.policy.allowedModels, sel) ? 'ready' : 'paused'}
                            word={allows(p.policy.allowedModels, sel) ? 'Allowed' : 'Not allowed'}
                        />
                    </div>
                    <div class="bd">
                        <dl class="kv sm">
                            <dt>Name agents use</dt>
                            <dd><code>{sel}</code>, in the <code>model</code> field of a definition</dd>
                            <dt>Policy</dt>
                            <dd>
                                {#if allows(p.policy.allowedModels, sel)}
                                    listed in <code>allowedModels</code>
                                {:else}
                                    not in the policy <code>allowedModels</code>: a definition that names it is refused
                                {/if}
                            </dd>
                            <dt>Gateway</dt>
                            <dd><code>{p.gatewayBaseUrl}</code></dd>
                            <dt>Used by</dt>
                            <dd><UsedBy names={usedBy(src.items, (a) => a.model === sel)} /></dd>
                        </dl>
                    </div>
                </aside>
            </div>
        {/if}
    {/snippet}
</PlatformGate>
