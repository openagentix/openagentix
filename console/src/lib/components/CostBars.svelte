<script lang="ts">
    // Spend per gateway user (an agent's key) as a bar list: one series, direct values, thin bars with a rounded data end.
    import { usd, type UserUse } from '$lib/metrics';

    interface Props {
        users: UserUse[];
    }
    let { users }: Props = $props();
    const top = $derived(Math.max(...users.map((u) => u.costUsd), 0.000001));
</script>

<ul class="costbars" aria-label="Spend per agent key">
    {#each users as u (u.user)}
        <li>
            <a class="mono name" href="/agents/{encodeURIComponent(u.user)}">{u.user}</a>
            <svg viewBox="0 0 100 8" preserveAspectRatio="none" class="cbar" aria-hidden="true">
                <rect x="0" y="0" width="100" height="8" rx="2" class="cb-track" />
                <rect
                    x="0"
                    y="0"
                    width={Math.max((u.costUsd / top) * 100, u.costUsd > 0 ? 1 : 0)}
                    height="8"
                    rx="2"
                    class="cb-fill"
                />
            </svg>
            <span class="num val">{usd(u.costUsd)}</span>
        </li>
    {/each}
</ul>
