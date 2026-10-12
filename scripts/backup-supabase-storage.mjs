import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

const supabaseUrl = required("SUPABASE_URL").replace(/\/$/, "");
const serviceRoleKey = required("SUPABASE_SERVICE_ROLE_KEY");
const bucket = required("STORAGE_BUCKET");
const outputDirectory = required("STORAGE_OUTPUT_DIR");

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Variavel obrigatoria ausente: ${name}`);
  return value;
}

function headers(contentType) {
  return {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    ...(contentType ? { "Content-Type": contentType } : {}),
  };
}

function encodeObjectPath(value) {
  return value.split("/").map(encodeURIComponent).join("/");
}

async function list(prefix = "") {
  const objects = [];
  let offset = 0;

  while (true) {
    const response = await fetch(`${supabaseUrl}/storage/v1/object/list/${encodeURIComponent(bucket)}`, {
      method: "POST",
      headers: headers("application/json"),
      body: JSON.stringify({ prefix, limit: 1000, offset, sortBy: { column: "name", order: "asc" } }),
    });

    if (!response.ok) {
      throw new Error(`Falha ao listar ${prefix || "/"}: ${response.status} ${await response.text()}`);
    }

    const entries = await response.json();
    for (const entry of entries) {
      const objectPath = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.id == null && entry.metadata == null) {
        objects.push(...await list(objectPath));
      } else {
        objects.push(objectPath);
      }
    }

    if (entries.length < 1000) break;
    offset += entries.length;
  }

  return objects;
}

async function download(objectPath) {
  const response = await fetch(
    `${supabaseUrl}/storage/v1/object/authenticated/${encodeURIComponent(bucket)}/${encodeObjectPath(objectPath)}`,
    { headers: headers() },
  );

  if (!response.ok) {
    throw new Error(`Falha ao baixar ${objectPath}: ${response.status} ${await response.text()}`);
  }

  const destination = path.join(outputDirectory, ...objectPath.split("/"));
  await mkdir(path.dirname(destination), { recursive: true });
  await writeFile(destination, Buffer.from(await response.arrayBuffer()));
}

await mkdir(outputDirectory, { recursive: true });
const objects = await list();

for (const [index, objectPath] of objects.entries()) {
  await download(objectPath);
  console.log(`[${index + 1}/${objects.length}] ${objectPath}`);
}

console.log(`${objects.length} comprovante(s) exportado(s).`);
