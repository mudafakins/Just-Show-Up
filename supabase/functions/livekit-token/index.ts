// Supabase Edge Function: livekit-token
//
// Hands the app a short-lived LiveKit access token for one call room.
// The LiveKit API secret stays here on the server and never ships in the app.
//
// Secrets to set (Edge Functions -> Secrets):
//   LIVEKIT_URL         wss://<your-project>.livekit.cloud
//   LIVEKIT_API_KEY
//   LIVEKIT_API_SECRET
//
// Request:  POST { "room": "<team id>:<anything>" }  with the user's session token
// Response: { "token": "...", "url": "wss://..." }

import { createClient } from "npm:@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const base64url = (data: Uint8Array | string) => {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

async function signJWT(payload: Record<string, unknown>, secret: string) {
  const unsigned = `${base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }))}.${
    base64url(JSON.stringify(payload))
  }`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  // Trim: a stray space or line break from copy-paste would make LiveKit reject the token.
  const livekitURL = Deno.env.get("LIVEKIT_URL")?.trim();
  const apiKey = Deno.env.get("LIVEKIT_API_KEY")?.trim();
  const apiSecret = Deno.env.get("LIVEKIT_API_SECRET")?.trim();
  if (!livekitURL || !apiKey || !apiSecret) {
    return json({ error: "LiveKit secrets are not set on the server." }, 500);
  }
  // Catch the common mix-ups early, with a message that says which secret is wrong.
  if (!livekitURL.startsWith("wss://")) {
    return json({ error: "LIVEKIT_URL must start with wss://" }, 500);
  }
  if (!apiKey.startsWith("API") || apiKey.length > 30) {
    return json({ error: "LIVEKIT_API_KEY does not look like a LiveKit API key (they start with API and are short)." }, 500);
  }
  if (apiSecret.startsWith("API") && apiSecret.length < 30) {
    return json({ error: "LIVEKIT_API_SECRET looks like an API key. The key and secret may be swapped." }, 500);
  }
  if (apiSecret.length < 30) {
    return json({ error: "LIVEKIT_API_SECRET looks too short. Paste the full secret." }, 500);
  }

  const authorization = req.headers.get("Authorization") ?? "";
  const supabaseKey = req.headers.get("apikey") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, supabaseKey, {
    global: { headers: { Authorization: authorization } },
  });

  // Who is asking? (Checks the session token with Supabase Auth.)
  const { data: auth, error: authError } = await supabase.auth.getUser(
    authorization.replace(/^Bearer\s+/i, ""),
  );
  if (authError || !auth?.user) return json({ error: "Not signed in." }, 401);

  // Which team are they on? Row-level security only returns their own team's rows.
  const { data: profile } = await supabase
    .from("profiles")
    .select("id, name, team_id")
    .eq("id", auth.user.id)
    .maybeSingle();
  if (!profile?.team_id) return json({ error: "You are not on a team." }, 403);

  // Rooms are named "<team id>:<suffix>", so a token only ever opens your own team's rooms.
  const { room } = await req.json().catch(() => ({ room: null }));
  if (typeof room !== "string" || room.length > 120 || !room.startsWith(`${profile.team_id}:`)) {
    return json({ error: "That room does not belong to your team." }, 403);
  }

  const now = Math.floor(Date.now() / 1000);
  const token = await signJWT(
    {
      iss: apiKey,
      sub: profile.id,
      name: profile.name,
      nbf: now - 10,
      exp: now + 6 * 60 * 60,
      video: {
        room,
        roomJoin: true,
        canPublish: true,
        canSubscribe: true,
        canPublishData: true,
      },
    },
    apiSecret,
  );

  return json({ token, url: livekitURL });
});
