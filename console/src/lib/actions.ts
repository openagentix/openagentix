// Small DOM actions shared by the dialog, the side sheet and the mobile drawer.

const FOCUSABLE =
    'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function focusables(root: HTMLElement): HTMLElement[] {
    return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
        (el) => !el.hasAttribute('hidden') && el.getAttribute('aria-hidden') !== 'true',
    );
}

export interface TrapOptions {
    /** A selector inside the node, or an element, to focus first. Default: the first focusable element. */
    initial?: string | HTMLElement;
    onescape?: () => void;
}

const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'TEMPLATE', 'LINK', 'META']);

/**
 * Makes everything that is not on the path from `node` up to the body inert, so that nothing behind an overlay can be
 * reached by keyboard, pointer or screen reader. Elements marked `data-overlay-part` (the scrim) or `data-inert-exempt`
 * (the toast live region) stay live. Returns the function that lifts exactly what it set.
 */
function inertBackground(node: HTMLElement): () => void {
    const changed: HTMLElement[] = [];
    let el: HTMLElement | null = node;
    while (el && el !== document.body) {
        const parent: HTMLElement | null = el.parentElement;
        if (!parent) break;
        for (const sib of Array.from(parent.children)) {
            if (sib === el || !(sib instanceof HTMLElement) || SKIP_TAGS.has(sib.tagName)) continue;
            if (
                sib.hasAttribute('data-overlay-part') ||
                sib.hasAttribute('data-inert-exempt') ||
                sib.hasAttribute('inert')
            )
                continue;
            sib.setAttribute('inert', '');
            changed.push(sib);
        }
        el = parent;
    }
    return () => changed.forEach((e) => e.removeAttribute('inert'));
}

/**
 * The focus handling of every overlay (dialog, side sheet, drawer): the background is inert while it exists, keyboard
 * focus stays inside it (Tab wraps, and focus that a mouse click or a script moved out is pulled back), Escape closes it,
 * and focus goes back to the element that had it before.
 */
export function trapFocus(node: HTMLElement, opts: TrapOptions = {}) {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    let current = opts;
    function first(): HTMLElement | null {
        const i = current.initial;
        if (typeof i === 'string') return node.querySelector<HTMLElement>(i);
        if (i) return i;
        return focusables(node)[0] ?? null;
    }
    const hadTabindex = node.hasAttribute('tabindex');
    if (!hadTabindex) node.setAttribute('tabindex', '-1'); // so that a click on empty space inside can still hold focus
    const lift = inertBackground(node);
    (first() ?? node).focus();
    let lastInside: HTMLElement | null = document.activeElement instanceof HTMLElement ? document.activeElement : null;

    function onkey(e: KeyboardEvent) {
        if (e.key === 'Escape') {
            e.stopPropagation();
            e.preventDefault();
            current.onescape?.();
            return;
        }
        if (e.key !== 'Tab') return;
        const els = focusables(node);
        if (els.length === 0) {
            e.preventDefault();
            return;
        }
        const a = els[0]!;
        const z = els[els.length - 1]!;
        const active = document.activeElement;
        if (e.shiftKey && (active === a || !node.contains(active))) {
            e.preventDefault();
            z.focus();
        } else if (!e.shiftKey && (active === z || !node.contains(active))) {
            e.preventDefault();
            a.focus();
        }
    }
    // focus moved to another element of the page (a script, or a click on something focusable): bring it back
    function onfocusin(e: FocusEvent) {
        const t = e.target;
        if (!(t instanceof Node)) return;
        if (node.contains(t)) {
            if (t instanceof HTMLElement) lastInside = t;
            return;
        }
        if (t instanceof Element && t.closest('[data-inert-exempt], [data-overlay-part]')) return;
        (lastInside && node.contains(lastInside) ? lastInside : (first() ?? node)).focus();
    }
    // focus fell to the body (a click on empty space): once the click has settled, take it back unless it is inside
    function onfocusout(e: FocusEvent) {
        if (e.relatedTarget instanceof Node) return; // onfocusin handles a move to an element
        setTimeout(() => {
            const a = document.activeElement;
            if (a && a !== document.body && a !== document.documentElement) return; // the window lost focus, or it is elsewhere
            (lastInside && node.contains(lastInside) ? lastInside : (first() ?? node)).focus();
        }, 0);
    }
    node.addEventListener('keydown', onkey);
    node.addEventListener('focusout', onfocusout);
    document.addEventListener('focusin', onfocusin);
    return {
        update(o: TrapOptions) {
            current = o;
        },
        destroy() {
            node.removeEventListener('keydown', onkey);
            node.removeEventListener('focusout', onfocusout);
            document.removeEventListener('focusin', onfocusin);
            if (!hadTabindex) node.removeAttribute('tabindex');
            lift(); // an inert element cannot take focus, so lift first
            if (opener && document.contains(opener)) opener.focus();
        },
    };
}

export async function copyText(text: string): Promise<boolean> {
    try {
        await navigator.clipboard.writeText(text);
        return true;
    } catch {
        // the clipboard API needs a secure context; localhost counts, a plain http address does not
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.className = 'sr';
        document.body.appendChild(ta);
        ta.select();
        let ok: boolean;
        try {
            ok = document.execCommand('copy');
        } catch {
            ok = false;
        }
        ta.remove();
        return ok;
    }
}
