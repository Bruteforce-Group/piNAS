/* eslint-disable no-console */
const encoder = new TextEncoder();

const CLIENT_INDEX_KEY = "clients:index";
const ARTIFACT_LATEST_KEY = "artifact:latest";
const ARTIFACT_HISTORY_PREFIX = "artifact:";

interface ArtifactMetadata {
  version: string;
  objectKey: string;
  sha256: string;
  size: number;
  uploadedAt: string;
  notes?: string;
}

interface ClientRecord {
  id: string;
  displayName?: string;
  tokenHash: string;
  status?: "active" | "inactive";
  createdAt?: string;
  updatedAt?: string;
  lastSeen?: string;
  lastIp?: string;
  currentVersion?: string;
  metrics?: Record<string, unknown>;
  notes?: string;
}

interface Env {
  ARTIFACTS_BUCKET: R2Bucket;
  CLIENTS_KV: KVNamespace;
  ADMIN_TOKEN?: string;
  CLIENT_POLL_INTERVAL_SECONDS?: string;
  DOCUMENTATION_URL?: string;
}

const jsonResponse = (body: unknown, init: ResponseInit = {}): Response => {
  const headers = new Headers(init.headers);
  if (!headers.has("content-type")) {
    headers.set("content-type", "application/json; charset=utf-8");
  }
  return new Response(JSON.stringify(body, null, 2), {
    ...init,
    headers,
  });
};

const textResponse = (body: string, init: ResponseInit = {}): Response => {
  const headers = new Headers(init.headers);
  if (!headers.has("content-type")) {
    headers.set("content-type", "text/plain; charset=utf-8");
  }
  return new Response(body, { ...init, headers });
};

const badRequest = (message: string): Response =>
  jsonResponse({ error: "bad_request", message }, { status: 400 });

const unauthorized = (): Response =>
  jsonResponse({ error: "unauthorized", message: "Missing or invalid credentials" }, { status: 401 });

const notFound = (): Response => jsonResponse({ error: "not_found" }, { status: 404 });

const sanitizeClientId = (value: string | null): string | null => {
  if (!value) {
    return null;
  }
  const trimmed = value.trim().toLowerCase();
  if (!/^[-a-z0-9_.]{3,64}$/.test(trimmed)) {
    return null;
  }
  return trimmed;
};

const hashValue = async (input: string): Promise<string> => {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
};

const getClientIndex = async (env: Env): Promise<string[]> => {
  const raw = await env.CLIENTS_KV.get(CLIENT_INDEX_KEY, "text");
  if (!raw) {
    return [];
  }
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch (_) {
    return [];
  }
};

const saveClientIndex = async (env: Env, ids: string[]): Promise<void> => {
  await env.CLIENTS_KV.put(CLIENT_INDEX_KEY, JSON.stringify([...new Set(ids)]));
};

const getClientKey = (id: string): string => `client:${id}`;

const getClientRecord = async (env: Env, id: string): Promise<ClientRecord | null> => {
  const data = await env.CLIENTS_KV.get<ClientRecord>(getClientKey(id), "json");
  return data ?? null;
};

const saveClientRecord = async (env: Env, record: ClientRecord): Promise<void> => {
  const payload = { ...record, updatedAt: new Date().toISOString() };
  await env.CLIENTS_KV.put(getClientKey(record.id), JSON.stringify(payload));
};

const deleteClientRecord = async (env: Env, id: string): Promise<void> => {
  await env.CLIENTS_KV.delete(getClientKey(id));
};

const publicClientRecord = (client: ClientRecord) => {
  const { tokenHash: _tokenHash, ...rest } = client;
  return rest;
};

const fetchLatestArtifact = async (env: Env): Promise<ArtifactMetadata | null> => {
  const data = await env.CLIENTS_KV.get<ArtifactMetadata>(ARTIFACT_LATEST_KEY, "json");
  return data ?? null;
};

const fetchArtifactByVersion = async (env: Env, version?: string | null): Promise<ArtifactMetadata | null> => {
  if (!version) {
    return null;
  }
  const key = `${ARTIFACT_HISTORY_PREFIX}${version}`;
  const data = await env.CLIENTS_KV.get<ArtifactMetadata>(key, "json");
  return data ?? null;
};

const saveArtifactMetadata = async (env: Env, metadata: ArtifactMetadata): Promise<void> => {
  await Promise.all([
    env.CLIENTS_KV.put(ARTIFACT_LATEST_KEY, JSON.stringify(metadata)),
    env.CLIENTS_KV.put(`${ARTIFACT_HISTORY_PREFIX}${metadata.version}`, JSON.stringify(metadata)),
  ]);
};

const verifyAdmin = (request: Request, env: Env): boolean => {
  const secret = env.ADMIN_TOKEN;
  if (!secret) {
    // If no admin secret is configured, deny by default.
    return false;
  }
  const header = request.headers.get("authorization");
  if (!header || !header.startsWith("Bearer ")) {
    return false;
  }
  const token = header.slice(7).trim();
  return token === secret;
};

const requireAdmin = (request: Request, env: Env): Response | null => {
  if (!verifyAdmin(request, env)) {
    return unauthorized();
  }
  return null;
};

const authenticateClient = async (request: Request, env: Env): Promise<ClientRecord | null> => {
  const id = sanitizeClientId(request.headers.get("x-client-id"));
  const token = request.headers.get("x-client-token")?.trim();
  if (!id || !token) {
    return null;
  }
  const record = await getClientRecord(env, id);
  if (!record) {
    return null;
  }
  const providedHash = await hashValue(token);
  if (providedHash !== record.tokenHash) {
    return null;
  }
  return record;
};

const handleHealthz = async (): Promise<Response> =>
  jsonResponse({ status: "ok", timestamp: new Date().toISOString() });

const handleAdminClients = async (
  request: Request,
  env: Env,
  segments: string[],
): Promise<Response> => {
  const authError = requireAdmin(request, env);
  if (authError) {
    return authError;
  }

  // /admin/clients
  if (segments.length === 2 && request.method === "GET") {
    const ids = await getClientIndex(env);
    const results = await Promise.all(ids.map((id) => getClientRecord(env, id)));
    const clients = results.filter((record): record is ClientRecord => Boolean(record)).map(publicClientRecord);
    return jsonResponse({ clients });
  }

  // /admin/clients/:id
  if (segments.length === 3) {
    const id = sanitizeClientId(segments[2]);
    if (!id) {
      return badRequest("Invalid client id");
    }

    if (request.method === "DELETE") {
      const ids = await getClientIndex(env);
      await deleteClientRecord(env, id);
      await saveClientIndex(env, ids.filter((value) => value !== id));
      return jsonResponse({ status: "deleted", id });
    }

    if (request.method === "PUT") {
      let payload: Partial<ClientRecord> & { token?: string };
      try {
        payload = await request.json();
      } catch (error) {
        console.error("Failed to parse client payload", error);
        return badRequest("Invalid JSON payload");
      }

      if (!payload.token) {
        return badRequest("Client token is required when registering");
      }

      const hashedToken = await hashValue(payload.token);
      const existing = await getClientRecord(env, id);

      const record: ClientRecord = {
        id,
        displayName: payload.displayName ?? existing?.displayName ?? id,
        tokenHash: hashedToken,
        status: payload.status ?? existing?.status ?? "active",
        notes: payload.notes ?? existing?.notes,
        createdAt: existing?.createdAt ?? new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        lastSeen: existing?.lastSeen,
        lastIp: existing?.lastIp,
        currentVersion: existing?.currentVersion,
        metrics: existing?.metrics,
      };

      await saveClientRecord(env, record);
      const ids = await getClientIndex(env);
      if (!ids.includes(id)) {
        ids.push(id);
        await saveClientIndex(env, ids);
      }

      return jsonResponse({ status: "ok", client: publicClientRecord(record) });
    }
  }

  return notFound();
};

const handleAdminArtifacts = async (request: Request, env: Env): Promise<Response> => {
  const authError = requireAdmin(request, env);
  if (authError) {
    return authError;
  }

  if (request.method === "GET") {
    const latest = await fetchLatestArtifact(env);
    return jsonResponse({ latest });
  }

  if (request.method !== "POST") {
    return badRequest("Unsupported method for artifacts endpoint");
  }

  let payload: Partial<ArtifactMetadata>;
  try {
    payload = await request.json();
  } catch (error) {
    console.error("Failed to parse artifact payload", error);
    return badRequest("Invalid JSON payload");
  }

  if (!payload.version || !payload.objectKey || !payload.sha256 || typeof payload.size !== "number") {
    return badRequest("version, objectKey, sha256, and size are required");
  }

  if (payload.size <= 0) {
    return badRequest("size must be greater than zero");
  }

  const metadata: ArtifactMetadata = {
    version: payload.version,
    objectKey: payload.objectKey,
    sha256: payload.sha256,
    size: payload.size,
    uploadedAt: new Date().toISOString(),
    notes: payload.notes,
  };

  await saveArtifactMetadata(env, metadata);

  return jsonResponse({ status: "ok", latest: metadata });
};

const handleClientState = async (request: Request, env: Env): Promise<Response> => {
  const client = await authenticateClient(request, env);
  if (!client) {
    return unauthorized();
  }

  let payload: Record<string, unknown> = {};
  try {
    if (request.body) {
      payload = await request.json();
    }
  } catch (error) {
    console.error("Failed to parse client state payload", error);
    return badRequest("Invalid JSON payload");
  }

  const currentVersion = typeof payload.currentVersion === "string" ? payload.currentVersion : client.currentVersion ?? "unknown";
  const metrics = typeof payload.metrics === "object" && payload.metrics !== null ? (payload.metrics as Record<string, unknown>) : undefined;
  const desiredVersion = typeof payload.desiredVersion === "string" ? payload.desiredVersion : undefined;
  const ip = request.headers.get("cf-connecting-ip") ?? request.headers.get("x-forwarded-for") ?? undefined;

  const now = new Date().toISOString();
  const updatedClient: ClientRecord = {
    ...client,
    currentVersion,
    lastSeen: now,
    lastIp: ip ?? client.lastIp,
    metrics: metrics ?? client.metrics,
  };

  await saveClientRecord(env, updatedClient);

  let targetArtifact = await fetchLatestArtifact(env);
  if (desiredVersion) {
    const requested = await fetchArtifactByVersion(env, desiredVersion);
    if (requested) {
      targetArtifact = requested;
    }
  }

  const pollInterval = parseInt(env.CLIENT_POLL_INTERVAL_SECONDS ?? "300", 10);
  const updateAvailable = Boolean(targetArtifact && targetArtifact.version && targetArtifact.version !== currentVersion);
  const downloadPath = targetArtifact ? `/artifact?objectKey=${encodeURIComponent(targetArtifact.objectKey)}` : null;

  return jsonResponse({
    clientId: client.id,
    updateAvailable,
    latest: targetArtifact,
    downloadPath,
    pollIntervalSeconds: Number.isFinite(pollInterval) ? pollInterval : 300,
    documentationUrl: env.DOCUMENTATION_URL,
  });
};

const handleArtifactDownload = async (request: Request, env: Env): Promise<Response> => {
  const client = await authenticateClient(request, env);
  if (!client) {
    return unauthorized();
  }

  const url = new URL(request.url);
  const objectKeyParam = url.searchParams.get("objectKey");
  if (!objectKeyParam) {
    return badRequest("objectKey query parameter is required");
  }

  const objectKey = objectKeyParam.replace(/^\/+/, "");
  const object = await env.ARTIFACTS_BUCKET.get(objectKey);
  if (!object || !object.body) {
    return notFound();
  }

  const filename = objectKey.split("/").pop() ?? "pinas-update.tar.gz";

  const headers = new Headers();
  headers.set("content-type", object.httpMetadata?.contentType ?? "application/gzip");
  headers.set("content-length", object.size?.toString() ?? "");
  headers.set("content-disposition", `attachment; filename="${filename}"`);
  headers.set("cache-control", "private, max-age=0, must-revalidate");

  return new Response(object.body, { headers });
};

const handleNotFound = async (): Promise<Response> => notFound();

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);

    if (segments.length === 0 && request.method === "GET") {
      return textResponse("piNAS deployment worker is online\n", { status: 200 });
    }

    if (segments[0] === "healthz") {
      return handleHealthz();
    }

    if (segments[0] === "admin") {
      if (segments[1] === "clients") {
        return handleAdminClients(request, env, segments);
      }
      if (segments[1] === "artifacts") {
        return handleAdminArtifacts(request, env);
      }
      return unauthorized();
    }

    if (segments[0] === "client" && segments[1] === "state") {
      if (request.method !== "POST") {
        return badRequest("Use POST for client state updates");
      }
      return handleClientState(request, env);
    }

    if (segments[0] === "artifact") {
      if (request.method !== "GET") {
        return badRequest("Use GET to download artifacts");
      }
      return handleArtifactDownload(request, env);
    }

    return handleNotFound();
  },
};
