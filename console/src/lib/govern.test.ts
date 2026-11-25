import { describe, expect, it } from 'vitest';
import { describeCron, methodWords, ruleWords } from './govern';

describe('describeCron', () => {
    it.each([
        ['*/5 * * * *', 'every 5 minutes'],
        ['* * * * *', 'every minute'],
        ['0 * * * *', 'every hour, on the hour'],
        ['30 7 * * *', 'every day at 07:30'],
        ['0 7 * * 1-5', 'on weekdays at 07:00'],
        ['0 9 * * 1', 'every Monday at 09:00'],
        ['15 23 * * 0', 'every Sunday at 23:15'],
        ['15 23 * * 7', 'every Sunday at 23:15'],
    ])('says %s in words', (cron, words) => {
        expect(describeCron(cron)).toBe(words);
    });
    it('gives up without guessing on anything else', () => {
        for (const c of ['0 7 1 * *', '0 7,19 * * *', '@daily', 'x', '', '0 7 * * 1,3', '61 7 * * *', '0 25 * * *'])
            expect(describeCron(c), c).toBe('');
    });
});

describe('words for the gate rules', () => {
    it('names the kind of user id rule without a value', () => {
        expect(ruleWords('exact')).toBe('one exact user id');
        expect(ruleWords('prefix')).toBe('any user id with a fixed start');
        expect(ruleWords('fixed')).toBe('set by the gate');
        expect(ruleWords('')).toBe('not set');
    });
    it('shortens the method list', () => {
        expect(methodWords(['SendMessage'])).toBe('send only');
        expect(methodWords(['SendMessage', 'SendStreamingMessage'])).toBe('send and stream');
        expect(methodWords(['SendMessage', 'GetTask', 'CancelTask'])).toBe('3 methods');
    });
});
