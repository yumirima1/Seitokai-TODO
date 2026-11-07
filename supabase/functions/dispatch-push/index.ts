import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

type PushDelivery = {
  queue_id: string;
  notification_id: string;
  recipient_id: string;
  title: string;
  body: string;
  resource_type: string | null;
  resource_id: string | null;
  attempt_count: number;
};

type PushSubscription = {
  id: string;
  user_id: string;
  endpoint: string;
  p256dh: string;
  auth_key: string;
};

async function constantTimeEqual(left: string, right: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [leftHash, rightHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const a = new Uint8Array(leftHash);
  const b = new Uint8Array(rightHash);
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) difference |= a[index] ^ b[index];
  return difference === 0;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const dispatchSecret = Deno.env.get("PUSH_DISPATCH_SECRET");
  const suppliedSecret = request.headers.get("x-push-dispatch-secret") || "";
  if (!dispatchSecret || !(await constantTimeEqual(suppliedSecret, dispatchSecret))) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY");
  const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY");
  const vapidSubject = Deno.env.get("VAPID_SUBJECT");
  if (!supabaseUrl || !serviceRoleKey || !vapidPublicKey || !vapidPrivateKey || !vapidSubject) {
    console.error("Web Push environment configuration is incomplete.");
    return new Response("Push service is not configured", { status: 500 });
  }

  try {
    webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);
    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: deliveries, error: claimError } = await supabase
      .rpc("claim_push_deliveries", { batch_size: 50 });
    if (claimError) throw claimError;

    const queue = (deliveries || []) as PushDelivery[];
    if (!queue.length) return Response.json({ processed: 0 });

    const recipientIds = [...new Set(queue.map((delivery) => delivery.recipient_id))];
    const { data: subscriptions, error: subscriptionsError } = await supabase
      .from("push_subscriptions")
      .select("id, user_id, endpoint, p256dh, auth_key")
      .in("user_id", recipientIds);
    if (subscriptionsError) throw subscriptionsError;

    const byRecipient = new Map<string, PushSubscription[]>();
    for (const subscription of (subscriptions || []) as PushSubscription[]) {
      const recipientSubscriptions = byRecipient.get(subscription.user_id) || [];
      recipientSubscriptions.push(subscription);
      byRecipient.set(subscription.user_id, recipientSubscriptions);
    }

    let processed = 0;
    for (const delivery of queue) {
      const recipientSubscriptions = byRecipient.get(delivery.recipient_id) || [];
      const staleSubscriptionIds: string[] = [];
      const failures: string[] = [];

      await Promise.all(recipientSubscriptions.map(async (subscription) => {
        try {
          await webpush.sendNotification(
            {
              endpoint: subscription.endpoint,
              keys: { p256dh: subscription.p256dh, auth: subscription.auth_key },
            },
            JSON.stringify({
              title: "筑前生徒会",
              body: "新しい通知があります。アプリを開いて確認してください。",
              url: "./",
              notificationId: delivery.notification_id,
            }),
            { TTL: 60 * 60 },
          );
        } catch (error) {
          const statusCode = Number((error as { statusCode?: number }).statusCode || 0);
          if (statusCode === 404 || statusCode === 410) {
            staleSubscriptionIds.push(subscription.id);
          } else {
            failures.push(error instanceof Error ? error.message : "Unknown Web Push error");
          }
        }
      }));

      if (staleSubscriptionIds.length) {
        const { error } = await supabase
          .from("push_subscriptions")
          .delete()
          .in("id", staleSubscriptionIds);
        if (error) failures.push(`Could not remove expired subscriptions: ${error.message}`);
      }

      const exhausted = delivery.attempt_count >= 10;
      const retryDelaySeconds = Math.min(3600, 30 * (2 ** (delivery.attempt_count - 1)));
      const update = failures.length
        ? {
          status: exhausted ? "failed" : "pending",
          available_at: new Date(Date.now() + retryDelaySeconds * 1000).toISOString(),
          last_error: failures.join("; ").slice(0, 1000),
          locked_at: null,
        }
        : {
          status: "sent",
          sent_at: new Date().toISOString(),
          last_error: null,
          locked_at: null,
        };
      const { error: updateError } = await supabase
        .from("push_delivery_queue")
        .update(update)
        .eq("id", delivery.queue_id);
      if (updateError) throw updateError;
      processed += 1;
    }

    return Response.json({ processed });
  } catch (error) {
    console.error("Web Push dispatch failed:", error);
    return new Response("Web Push dispatch failed", { status: 500 });
  }
});
