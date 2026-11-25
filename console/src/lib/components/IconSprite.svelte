<script lang="ts">
    // no props: the sprite is rendered once by the root layout
</script>

<!-- The icon set of the approved mockup, as one inline sprite, rendered once by the root layout. Icons are referenced with <use>. -->
<svg class="sprite" width="0" height="0" aria-hidden="true" focusable="false">
    <defs>
        <symbol id="i-overview" viewBox="0 0 16 16"
            ><rect x="2" y="2" width="5" height="5" rx="1" /><rect x="9" y="2" width="5" height="5" rx="1" /><rect
                x="2"
                y="9"
                width="5"
                height="5"
                rx="1"
            /><rect x="9" y="9" width="5" height="5" rx="1" /></symbol
        >
        <symbol id="i-agent" viewBox="0 0 16 16"
            ><rect x="3" y="4" width="10" height="9" rx="2" /><path d="M8 1.5V4M6 8h.01M10 8h.01M6 11h4" /></symbol
        >
        <symbol id="i-play" viewBox="0 0 16 16"
            ><path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z" /><path d="M5.5 6.5h5M5.5 8.5h3" /></symbol
        >
        <symbol id="i-skill" viewBox="0 0 16 16"
            ><path d="M3 2.5h7l3 3v8H3z" /><path d="M10 2.5v3h3M5.5 8.5h5M5.5 11h3" /></symbol
        >
        <symbol id="i-model" viewBox="0 0 16 16"
            ><path d="M8 2 14 5 8 8 2 5z" /><path d="M2 8l6 3 6-3M2 11l6 3 6-3" /></symbol
        >
        <symbol id="i-tool" viewBox="0 0 16 16"
            ><path
                d="M10.5 2.5a3 3 0 0 0-3 3.9L2.8 11.1a1.4 1.4 0 0 0 2 2l4.7-4.6a3 3 0 0 0 3.9-3l-1.8 1.7-1.8-.2-.2-1.8z"
            /></symbol
        >
        <symbol id="i-book" viewBox="0 0 16 16"
            ><path
                d="M2.5 3h4a1.5 1.5 0 0 1 1.5 1.5V13a1.5 1.5 0 0 0-1.5-1.5h-4zM13.5 3h-4A1.5 1.5 0 0 0 8 4.5V13a1.5 1.5 0 0 1 1.5-1.5h4z"
            /></symbol
        >
        <symbol id="i-graph" viewBox="0 0 16 16"
            ><circle cx="4" cy="4" r="1.8" /><circle cx="12" cy="5" r="1.8" /><circle cx="7" cy="12" r="1.8" /><path
                d="M5.7 4.4l4.5.4M4.8 5.6l1.5 4.7M10.8 6.5l-2.7 4"
            /></symbol
        >
        <symbol id="i-channel" viewBox="0 0 16 16"><path d="M2 8h3l2-4.5 2 9 2-4.5h3" /></symbol>
        <symbol id="i-clock" viewBox="0 0 16 16"><circle cx="8" cy="8" r="5.8" /><path d="M8 4.8V8l2.2 1.4" /></symbol>
        <symbol id="i-trace" viewBox="0 0 16 16"><path d="M2 3.5h7M4 6.5h8M6 9.5h4M8 12.5h6" /></symbol>
        <symbol id="i-coin" viewBox="0 0 16 16"
            ><circle cx="8" cy="8" r="5.8" /><path
                d="M9.8 5.8c-.4-.6-1-.9-1.8-.9-1 0-1.8.5-1.8 1.3 0 1.9 3.8 1 3.8 3 0 .8-.9 1.4-2 1.4-.9 0-1.6-.3-2-1M8 3.8v1.1M8 11.1v1.1"
            /></symbol
        >
        <symbol id="i-memory" viewBox="0 0 16 16"
            ><ellipse cx="8" cy="4" rx="5" ry="1.8" /><path
                d="M3 4v8c0 1 2.2 1.8 5 1.8s5-.8 5-1.8V4M3 8c0 1 2.2 1.8 5 1.8s5-.8 5-1.8"
            /></symbol
        >
        <symbol id="i-shield" viewBox="0 0 16 16"
            ><path d="M8 1.8 13 3.6v4c0 3-2.1 5.4-5 6.6-2.9-1.2-5-3.6-5-6.6v-4z" /><path
                d="M5.8 8l1.6 1.6 3-3.2"
            /></symbol
        >
        <symbol id="i-gear" viewBox="0 0 16 16"
            ><circle cx="8" cy="8" r="2" /><path
                d="M8 1.8v1.6M8 12.6v1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M1.8 8h1.6M12.6 8h1.6M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1"
            /></symbol
        >
        <symbol id="i-lock" viewBox="0 0 16 16"
            ><rect x="3.5" y="7" width="9" height="6.5" rx="1.2" /><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" /></symbol
        >
        <symbol id="i-nodata" viewBox="0 0 16 16"
            ><circle cx="8" cy="8" r="5.5" stroke-dasharray="2 2.2" /><path d="M8 8h.01" /></symbol
        >
        <symbol id="i-search" viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.5" /><path d="m10.5 10.5 3 3" /></symbol>
        <symbol id="i-theme" viewBox="0 0 16 16"
            ><circle cx="8" cy="8" r="5.8" /><path d="M8 2.2v11.6A5.8 5.8 0 0 0 8 2.2z" fill="currentColor" /></symbol
        >
        <symbol id="i-plus" viewBox="0 0 16 16"><path d="M8 3v10M3 8h10" /></symbol>
        <symbol id="i-copy" viewBox="0 0 16 16"
            ><rect x="5" y="5" width="8.5" height="8.5" rx="1.3" /><path
                d="M3 10.5V3.8A1.3 1.3 0 0 1 4.3 2.5H10.5"
            /></symbol
        >
        <symbol id="i-trash" viewBox="0 0 16 16"><path d="M2.5 4.5h11M6 4.5V3h4v1.5M4 4.5l.7 9h6.6l.7-9" /></symbol>
        <symbol id="i-code" viewBox="0 0 16 16"><path d="M5.5 4 2 8l3.5 4M10.5 4 14 8l-3.5 4" /></symbol>
        <symbol id="i-x" viewBox="0 0 16 16"><path d="M4 4l8 8M12 4l-8 8" /></symbol>
        <symbol id="i-menu" viewBox="0 0 16 16"><path d="M2.5 4h11M2.5 8h11M2.5 12h11" /></symbol>
        <symbol id="i-side" viewBox="0 0 16 16"
            ><rect x="2" y="2.5" width="12" height="11" rx="1.5" /><path d="M6 2.5v11" /></symbol
        >
        <symbol id="i-chev" viewBox="0 0 16 16"><path d="m6 3.5 4.5 4.5L6 12.5" /></symbol>
        <symbol id="i-send" viewBox="0 0 16 16"><path d="M2.5 8 13.5 2.5 10.5 13.5 8 9z" /></symbol>
        <symbol id="i-info" viewBox="0 0 16 16"><circle cx="8" cy="8" r="5.8" /><path d="M8 7.3v3.7M8 5h.01" /></symbol>
        <symbol id="i-ext" viewBox="0 0 16 16"><path d="M9 2.5h4.5V7M13.5 2.5 7.5 8.5M11.5 9.5v3.5h-9v-9H6" /></symbol>
        <symbol id="s-ready" viewBox="0 0 16 16"
            ><circle cx="8" cy="8" r="6.2" fill="currentColor" stroke="none" /><path
                d="m5.2 8.2 1.9 1.9 3.8-4"
                stroke="var(--color-surface)"
                stroke-width="1.8"
                fill="none"
            /></symbol
        >
        <symbol id="s-pending" viewBox="0 0 16 16"
            ><circle cx="8" cy="8" r="5.6" stroke-width="1.6" fill="none" /><path
                d="M8 2.4a5.6 5.6 0 0 1 0 11.2z"
                fill="currentColor"
                stroke="none"
            /></symbol
        >
        <symbol id="s-refused" viewBox="0 0 16 16"
            ><circle cx="8" cy="8" r="6.2" fill="currentColor" stroke="none" /><path
                d="M4.8 8h6.4"
                stroke="var(--color-surface)"
                stroke-width="1.9"
            /></symbol
        >
        <symbol id="s-error" viewBox="0 0 16 16"
            ><path d="M8 1.8 14.6 13.6H1.4z" fill="currentColor" stroke="none" /><path
                d="M8 6v3.6M8 11.5h.01"
                stroke="var(--color-surface)"
                stroke-width="1.7"
            /></symbol
        >
        <symbol id="s-paused" viewBox="0 0 16 16"
            ><circle cx="8" cy="8" r="6.2" fill="currentColor" stroke="none" /><path
                d="M6.4 5.5v5M9.6 5.5v5"
                stroke="var(--color-surface)"
                stroke-width="1.7"
            /></symbol
        >
        <symbol id="s-none" viewBox="0 0 16 16"
            ><circle cx="8" cy="8" r="5.6" stroke-dasharray="2 2" fill="none" /></symbol
        >
    </defs>
</svg>
