// ============================================================
//  Shop Time Clock — settings. Fill in the two Supabase values
//  (see SETUP.md, step 2). Leave the push key as it is.
// ============================================================
window.TC_CONFIG = {
  SHOP_NAME: "Shop Time Clock",

  // Supabase > Project Settings > API (or "API Keys")
  SUPABASE_URL: "https://YOUR-PROJECT-ID.supabase.co",
  SUPABASE_KEY: "PASTE-YOUR-PUBLISHABLE-OR-ANON-KEY-HERE",

  // Public half of the push-notification key pair (safe to share)
  VAPID_PUBLIC_KEY: "BPgNDPFaCQ1wb3h97AWQmeX1oWxu7oeaufP9UqjY4PKPzyYVh9hFHQS_ZqTX7MNQ7B5A4efXcxixwrAfXsVgzAU"
};
