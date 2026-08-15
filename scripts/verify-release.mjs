import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { extname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const expectedDocs = [
    "01-arquitectura.md",
    "02-cuentas-y-margen.md",
    "03-interes-y-liquidez.md",
    "04-liquidaciones.md",
    "05-stress-de-capital.md",
    "06-operacion-y-observabilidad.md",
    "07-despliegue.md",
];

function fail(message) {
    console.error(`release verification failed: ${message}`);
    process.exitCode = 1;
}

function walk(directory, extensions) {
    if (!existsSync(directory)) return [];
    return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
        const path = join(directory, entry.name);
        if (entry.isDirectory()) return walk(path, extensions);
        return entry.isFile() && extensions.has(extname(entry.name)) ? [path] : [];
    });
}

function count(pattern, paths) {
    return paths.reduce((total, path) => {
        const matches = readFileSync(path, "utf8").match(pattern);
        return total + (matches?.length ?? 0);
    }, 0);
}

const packageJson = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
if (packageJson.version !== "1.0.0") fail("package version must be 1.0.0");
if (!existsSync(join(root, "package-lock.json"))) fail("package-lock.json is required");

const actualDocs = readdirSync(join(root, "docs"))
    .filter((name) => name.endsWith(".md"))
    .sort();
if (JSON.stringify(actualDocs) !== JSON.stringify(expectedDocs)) {
    fail(`docs manifest differs: ${actualDocs.join(", ")}`);
}

const markdown = [
    join(root, "README.md"),
    join(root, "SECURITY.md"),
    ...actualDocs.map((name) => join(root, "docs", name)),
];
const diagrams = count(/```mermaid/gu, markdown);
if (diagrams !== 27) fail(`expected 27 Mermaid diagrams, found ${diagrams}`);

const publicFiles = [
    ...markdown,
    ...walk(join(root, "src"), new Set([".sol"])),
    ...walk(join(root, "tests"), new Set([".ts"])),
];
const restricted = /\b(?:ctf|laboratorio|vulnerabilidad|vulnerable|exploit|bypass|atacante)\b/iu;
for (const path of publicFiles) {
    if (restricted.test(readFileSync(path, "utf8"))) {
        fail(`restricted public terminology in ${relative(root, path)}`);
    }
}

const banner = readFileSync(join(root, "assets", "banner.png"));
if (banner.length < 300_000 || banner.toString("ascii", 1, 4) !== "PNG") {
    fail("banner must be a production PNG of at least 300 KB");
} else if (banner.readUInt32BE(16) < 1_600 || banner.readUInt32BE(20) < 900) {
    fail("banner dimensions must be at least 1600x900");
}

const tests = count(/\bit\s*\(/gu, walk(join(root, "tests"), new Set([".ts"])));
if (tests < 16) fail(`expected at least 16 public tests, found ${tests}`);

const protectedFiles = JSON.parse(
    readFileSync(join(root, "scripts", "protected-files.json"), "utf8"),
);
for (const [path, expected] of Object.entries(protectedFiles)) {
    const actual = execFileSync("git", ["hash-object", path], {
        cwd: root,
        encoding: "utf8",
    }).trim();
    if (actual !== expected) fail(`compatibility hash differs for ${path}`);
}

if (!existsSync(join(root, "typechain-types", "core", "CapitalStressEngine.ts"))) {
    fail("CapitalStressEngine TypeChain binding is missing");
}

if (!process.exitCode) {
    console.log(
        `release verified: ${actualDocs.length} docs, ${diagrams} diagrams, ${tests} tests`,
    );
}
