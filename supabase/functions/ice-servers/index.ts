// Ways for two teammates' computers to reach each other when sending files.
//
// Always: public STUN servers (the apps fall back to these on their own too).
// Optionally: a Cloudflare TURN relay, for networks that block direct connections.
// To switch the relay on, add two secrets in Supabase (Edge Functions → Secrets):
//   CLOUDFLARE_TURN_KEY_ID     the TURN key's id
//   CLOUDFLARE_TURN_API_TOKEN  the TURN key's API token
// The apps never see these; they get short-lived relay passes from this function.

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const STUN = [{ urls: ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"] }];

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const keyId = Deno.env.get("CLOUDFLARE_TURN_KEY_ID");
  const token = Deno.env.get("CLOUDFLARE_TURN_API_TOKEN");
  if (!keyId || !token) return json({ iceServers: STUN });

  try {
    const res = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ ttl: 3600 }),
    });
    if (!res.ok) return json({ iceServers: STUN });
    const data = await res.json();
    // Cloudflare returns either a list or a single server object.
    const relays = Array.isArray(data.iceServers) ? data.iceServers : [data.iceServers];
    const servers = relays
      .filter(Boolean)
      .map((s: { urls: string | string[]; username?: string; credential?: string }) => ({
        urls: Array.isArray(s.urls) ? s.urls : [s.urls],
        username: s.username,
        credential: s.credential,
      }));
    return json({ iceServers: [...STUN, ...servers] });
  } catch {
    return json({ iceServers: STUN });
  }
});
