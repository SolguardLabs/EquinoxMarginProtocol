import { readdirSync, readFileSync } from "node:fs";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));

function walk(directory) {
    return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
        const path = join(directory, entry.name);
        if (entry.isDirectory()) return walk(path);
        return entry.isFile() && extname(entry.name) === ".sol" ? [path] : [];
    });
}

const lines = walk(join(root, "src")).reduce(
    (total, path) =>
        total +
        readFileSync(path, "utf8")
            .split(/\r?\n/u)
            .filter((line) => line.trim()).length,
    0,
);

if (lines < 3_300 || lines > 3_900) {
    console.error(`Solidity LOC fuera de rango: ${lines} (esperado 3300-3900)`);
    process.exit(1);
}

console.log(`Solidity LOC: ${lines}`);
