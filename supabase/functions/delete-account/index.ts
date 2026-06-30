// delete-account edge function.
//
// The `public.delete_account()` SQL RPC deletes the caller's profile, which
// cascades all of their public ride data. It cannot remove the `auth.users`
// row itself (a postgres-owned SECURITY DEFINER function lacks privilege on
// `auth.users`, owned by supabase_auth_admin). This function finishes the job:
// it authenticates the caller from their JWT, then uses the service-role admin
// API to delete the auth user — so the account truly cannot sign back in
// (App Store guideline 5.1.1(v)).
//
// The app calls this right after `delete_account()`. Verified end-to-end in the
// Task 12 Tier-3 integration pass.
//
// deno-lint-ignore-file no-explicit-any
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "missing authorization" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Resolve the caller from their JWT (anon client bound to their token).
  const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await caller.auth.getUser();
  if (userErr || !userData?.user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }
  const uid = userData.user.id;

  // Service-role client deletes the auth user. The profile + all public ride
  // data are removed by delete_account()'s cascade, which the app calls first.
  const admin = createClient(url, serviceKey);
  const { error: delErr } = await admin.auth.admin.deleteUser(uid);
  if (delErr) {
    return new Response(JSON.stringify({ error: delErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
  return new Response(JSON.stringify({ deleted: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
