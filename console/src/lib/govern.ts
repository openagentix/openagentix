// Words for the Schedules and Access pages. Nothing here guesses: a cron expression it does not know stays as it is.

const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const num = (s: string, max: number) => (/^\d{1,2}$/.test(s) && Number(s) <= max ? Number(s) : -1);
const two = (n: number) => String(n).padStart(2, '0');

/** A cron expression in plain English for the common shapes, or '' when it is not one of them. */
export function describeCron(cron: string): string {
    const f = cron.trim().split(/\s+/);
    if (f.length !== 5) return '';
    const [min, hour, dom, mon, dow] = f as [string, string, string, string, string];
    if (dom !== '*' || mon !== '*') return '';
    if (min === '*' && hour === '*' && dow === '*') return 'every minute';
    const step = /^\*\/(\d{1,2})$/.exec(min);
    if (step && hour === '*' && dow === '*' && Number(step[1]) >= 2 && Number(step[1]) <= 59)
        return `every ${step[1]} minutes`;
    const m = num(min, 59);
    if (m < 0) return '';
    if (hour === '*' && dow === '*') return m === 0 ? 'every hour, on the hour' : '';
    const h = num(hour, 23);
    if (h < 0) return '';
    const at = `${two(h)}:${two(m)}`;
    if (dow === '*') return `every day at ${at}`;
    if (dow === '1-5') return `on weekdays at ${at}`;
    const d = num(dow, 7);
    if (d < 0) return '';
    return `every ${DAYS[d % 7]} at ${at}`;
}

/** The kind of user id rule. The value is never sent by the API, so it is never shown. */
export function ruleWords(rule: string): string {
    switch (rule) {
        case 'exact':
            return 'one exact user id';
        case 'prefix':
            return 'any user id with a fixed start';
        case 'fixed':
            return 'set by the gate';
        default:
            return 'not set';
    }
}

/** A short phrase for a caller's methods; the detail view lists them all. */
export function methodWords(methods: string[]): string {
    const has = (m: string) => methods.includes(m);
    if (methods.length === 1 && has('SendMessage')) return 'send only';
    if (methods.length === 2 && has('SendMessage') && has('SendStreamingMessage')) return 'send and stream';
    return `${methods.length} method${methods.length === 1 ? '' : 's'}`;
}
