import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export type PackageInfo = { name: string; version: string; location: string };

/**
 * Name, version and directory of an installed package, read from its package.json. Packages with an
 * `exports` map (the Copilot SDK among them) don't export `package.json`, so this resolves the entry
 * point and walks up to the manifest that carries the package's name.
 */
export function packageInfo(name: string): PackageInfo {
  try {
    let dir = dirname(fileURLToPath(import.meta.resolve(name)));
    while (true) {
      const manifest = join(dir, "package.json");
      if (existsSync(manifest)) {
        const pkg = JSON.parse(readFileSync(manifest, "utf8")) as { name?: string; version?: string };
        if (pkg.name === name) return { name, version: pkg.version ?? "unknown", location: dir };
      }
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  } catch {
    // Not installed, or not resolvable from here.
  }
  return { name, version: "unknown", location: "unknown" };
}
