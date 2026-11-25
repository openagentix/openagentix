// Renders static/img/social-card.svg to static/img/social-card.png (1200x630). Run: npm run social-card
import {Resvg} from '@resvg/resvg-js';
import fs from 'node:fs';

const dir = new URL('../static/img/', import.meta.url);
const svg = fs.readFileSync(new URL('social-card.svg', dir));
const png = new Resvg(svg, {fitTo: {mode: 'width', value: 1200}, font: {loadSystemFonts: true}}).render().asPng();
fs.writeFileSync(new URL('social-card.png', dir), png);
console.log('wrote social-card.png', png.length, 'bytes');
