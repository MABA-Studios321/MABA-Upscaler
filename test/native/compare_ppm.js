// Compare two P6 PPM files: max and mean absolute channel difference (0-255 scale).
// Usage: node compare_ppm.js a.ppm b.ppm [maxTolerance]
const fs = require('fs');
function readPpm(p) {
    const b = fs.readFileSync(p);
    let off = 0;
    const token = () => {
        while (off < b.length && (b[off] === 32 || b[off] === 10 || b[off] === 13 || b[off] === 9)) off++;
        if (b[off] === 35) { while (off < b.length && b[off] !== 10) off++; return token(); }
        let s = off;
        while (off < b.length && b[off] > 32) off++;
        return b.slice(s, off).toString();
    };
    const magic = token(), w = +token(), h = +token(), maxv = +token();
    off++; // single whitespace after maxval
    if (magic !== 'P6') throw new Error('not P6: ' + p);
    return { w, h, data: b.slice(off, off + w * h * 3) };
}
const a = readPpm(process.argv[2]), b = readPpm(process.argv[3]);
const tol = process.argv[4] !== undefined ? +process.argv[4] : 4;
if (a.w !== b.w || a.h !== b.h) { console.log(`SIZE MISMATCH ${a.w}x${a.h} vs ${b.w}x${b.h}`); process.exit(1); }
let max = 0, sum = 0, n = a.data.length, over = 0;
for (let i = 0; i < n; i++) {
    const d = Math.abs(a.data[i] - b.data[i]);
    if (d > max) max = d;
    if (d > tol) over++;
    sum += d;
}
console.log(`${process.argv[2].split(/[\\/]/).pop()} vs ${process.argv[3].split(/[\\/]/).pop()}: max=${max} mean=${(sum / n).toFixed(3)} pixelsOverTol=${over}`);
process.exit(max <= tol ? 0 : 1);