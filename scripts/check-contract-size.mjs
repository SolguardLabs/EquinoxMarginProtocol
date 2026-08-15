import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const artifacts = join(root, "artifacts", "src");
const limit = 24_576;

function walk(directory) {
    if (!existsSync(directory)) return [];
    return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
        const path = join(directory, entry.name);
        if (entry.isDirectory()) return walk(path);
        if (entry.isFile() && path.endsWith(".json") && !path.endsWith(".dbg.json")) {
            return [path];
        }
        return [];
    });
}

let checked = 0;
for (const path of walk(artifacts)) {
    const artifact = JSON.parse(readFileSync(path, "utf8"));
    if (typeof artifact.deployedBytecode !== "string" || artifact.deployedBytecode === "0x") {
        continue;
    }
    const size = (artifact.deployedBytecode.length - 2) / 2;
    checked += 1;
    console.log(`${artifact.contractName}: ${size} bytes`);
    if (size > limit) {
        console.error(`${artifact.contractName} excede el limite EIP-170 de ${limit} bytes`);
        process.exitCode = 1;
    }
}

if (checked === 0) {
    console.error("No se encontraron contratos desplegables compilados");
    process.exit(1);
}
