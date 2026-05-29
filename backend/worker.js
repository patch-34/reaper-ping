const SERVICE_NAME = "patch34-render-telegram-bot";
const BACKEND_VERSION = "0.1.0-backend";

const KV_BINDING_NAME = "PATCH34_RENDER_BOT_KV";
const PAIR_TTL_SECONDS = 10 * 60;
const DEVICE_TOKEN_BYTES = 32;
const REPOSITORY_URL = "https://github.com/patch-34/reaper-ping";

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);

      if (request.method === "GET" && url.pathname === "/health") {
        return jsonResponse({
          ok: true,
          service: SERVICE_NAME,
          version: BACKEND_VERSION,
        });
      }

      if (request.method === "POST" && url.pathname === "/telegram/webhook") {
        return handleTelegramWebhook(request, env);
      }

      if (request.method === "POST" && url.pathname === "/pair") {
        return handlePair(request, env);
      }

      if (request.method === "POST" && url.pathname === "/notify") {
        return handleNotify(request, env);
      }

      return jsonResponse(
        {
          ok: false,
          error: "not_found",
        },
        404,
      );
    } catch (error) {
      return jsonResponse(
        {
          ok: false,
          error: "internal_error",
          message: safeErrorMessage(error),
        },
        500,
      );
    }
  },
};

async function handleTelegramWebhook(request, env) {
  const update = await readJson(request);
  const callbackQuery = update && update.callback_query ? update.callback_query : null;

  if (callbackQuery) {
    return handleTelegramCallbackQuery(callbackQuery, env);
  }

  const message = update && update.message ? update.message : null;
  const text = message && typeof message.text === "string" ? message.text.trim() : "";
  const chatId = message && message.chat ? message.chat.id : null;

  if (!chatId) {
    return jsonResponse({
      ok: true,
      ignored: true,
      reason: "missing_chat_id",
    });
  }

  if (isInstructionCommand(text)) {
    const pairingCode = await createStoredPairingCode(env, chatId);

    await sendTelegramMessage(env, {
      chatId,
      text: buildPairingInstructionsRu(pairingCode),
      replyMarkup: buildInstructionLanguageReplyMarkup("ru", pairingCode),
    });

    return jsonResponse({
      ok: true,
      handled: true,
    });
  }

  if (isPairCommand(text)) {
    const pairingCode = await createStoredPairingCode(env, chatId);

    await sendTelegramMessage(env, {
      chatId,
      text: buildShortPairingMessage(pairingCode),
    });

    return jsonResponse({
      ok: true,
      handled: true,
    });
  }

  await sendTelegramMessage(env, {
    chatId,
    text: [
      "Напиши /start или /pair, чтобы получить код подключения.",
      "Send /start or /pair to get a pairing code.",
    ].join("\n"),
  });

  return jsonResponse({
    ok: true,
    handled: true,
    fallback: true,
  });
}

function isInstructionCommand(text) {
  return (
    text === "/start" ||
    text === "/help" ||
    text.startsWith("/start ") ||
    text.startsWith("/help ")
  );
}

function isPairCommand(text) {
  return text === "/pair" || text.startsWith("/pair ");
}

async function handleTelegramCallbackQuery(callbackQuery, env) {
  const callbackQueryId = callbackQuery && callbackQuery.id ? callbackQuery.id : "";
  const data = callbackQuery && typeof callbackQuery.data === "string" ? callbackQuery.data : "";
  const message = callbackQuery && callbackQuery.message ? callbackQuery.message : null;
  const chatId = message && message.chat ? message.chat.id : null;
  const messageId = message && message.message_id ? message.message_id : null;
  const match = data.match(/^lang:(ru|en):instructions:([A-Z0-9]{6})$/);

  if (!callbackQueryId) {
    return jsonResponse({
      ok: true,
      ignored: true,
      reason: "missing_callback_query_id",
    });
  }

  if (!match || !chatId || !messageId) {
    await answerCallbackQuery(env, {
      callbackQueryId,
      text: "Unsupported action",
    });

    return jsonResponse({
      ok: true,
      handled: true,
      ignored: true,
    });
  }

  const language = match[1];
  const pairingCode = match[2];

  await answerCallbackQuery(env, {
    callbackQueryId,
  });

  await editTelegramMessageText(env, {
    chatId,
    messageId,
    text: language === "en" ? buildPairingInstructionsEn(pairingCode) : buildPairingInstructionsRu(pairingCode),
    replyMarkup: buildInstructionLanguageReplyMarkup(language, pairingCode),
  });

  return jsonResponse({
    ok: true,
    handled: true,
  });
}

async function createStoredPairingCode(env, chatId) {
  const pairingCode = await generateUniquePairingCode(env);
  const now = Date.now();
  const expiresAt = now + PAIR_TTL_SECONDS * 1000;

  await env[KV_BINDING_NAME].put(
    pairKey(pairingCode),
    JSON.stringify({
      chat_id: String(chatId),
      created_at: new Date(now).toISOString(),
      expires_at: new Date(expiresAt).toISOString(),
      used: false,
    }),
    {
      expirationTtl: PAIR_TTL_SECONDS,
    },
  );

  return pairingCode;
}

function buildInstructionLanguageReplyMarkup(currentLanguage, pairingCode) {
  const nextLanguage = currentLanguage === "en" ? "ru" : "en";
  const label = nextLanguage === "en" ? "EN" : "RU";

  return {
    inline_keyboard: [
      [
        {
          text: label,
          callback_data: `lang:${nextLanguage}:instructions:${pairingCode}`,
        },
      ],
    ],
  };
}

function buildShortPairingMessage(pairingCode) {
  return [
    "Reaper Ping pairing code:",
    pairingCode,
    "",
    "Then in REAPER, use this code to connect your notifier.",
  ].join("\n");
}

function buildPairingInstructionsRu(pairingCode) {
  return [
    "Привет! Я Reaper Ping.",
    "",
    "Я отправляю сообщение в Telegram, когда рендер в REAPER завершён.",
    "",
    "Как подключить:",
    "",
    "1. Открой страницу проекта:",
    REPOSITORY_URL,
    "",
    "2. Скачай файл скрипта:",
    "Patch34 - Render with Telegram notification.lua",
    "",
    "3. В REAPER открой:",
    "Actions → Show action list → New action → Load ReaScript",
    "",
    "4. Выбери скачанный файл:",
    "Patch34 - Render with Telegram notification.lua",
    "",
    "5. Запусти action:",
    "Patch34: Render with Telegram notification",
    "",
    "6. Когда REAPER попросит код подключения, вставь этот pairing code:",
    "",
    pairingCode,
    "",
    "После подключения используй Patch34 action каждый раз, когда хочешь получить уведомление о завершении рендера.",
    "",
    "Обычный Render в REAPER не отправляет уведомления.",
    "Уведомления приходят только для рендеров, запущенных через Patch34 action.",
  ].join("\n");
}

function buildPairingInstructionsEn(pairingCode) {
  return [
    "Hi! I’m Reaper Ping.",
    "",
    "I send you a Telegram message when your REAPER render is finished.",
    "",
    "How to connect:",
    "",
    "1. Open the project page:",
    REPOSITORY_URL,
    "",
    "2. Download the script file:",
    "Patch34 - Render with Telegram notification.lua",
    "",
    "3. In REAPER, open:",
    "Actions → Show action list → New action → Load ReaScript",
    "",
    "4. Select the downloaded file:",
    "Patch34 - Render with Telegram notification.lua",
    "",
    "5. Run the action:",
    "Patch34: Render with Telegram notification",
    "",
    "6. When REAPER asks for a pairing code, paste this code:",
    "",
    pairingCode,
    "",
    "After pairing, use the Patch34 action whenever you want a render notification.",
    "",
    "Regular REAPER Render will not send notifications.",
    "Only renders started through the Patch34 action will ping you.",
  ].join("\n");
}

async function handlePair(request, env) {
  const body = await readJson(request);
  const pairingCode = normalizePairingCode(body && body.pairing_code);
  const deviceName = sanitizeDeviceName(body && body.device_name);

  if (!pairingCode) {
    return jsonResponse(
      {
        ok: false,
        error: "missing_pairing_code",
        message: "pairing_code is required",
      },
      400,
    );
  }

  const stored = await env[KV_BINDING_NAME].get(pairKey(pairingCode), { type: "json" });

  if (!stored) {
    return jsonResponse(
      {
        ok: false,
        error: "invalid_or_expired_pairing_code",
        message: "Pairing code is invalid or expired",
      },
      400,
    );
  }

  if (stored.used) {
    return jsonResponse(
      {
        ok: false,
        error: "pairing_code_used",
        message: "Pairing code has already been used",
      },
      400,
    );
  }

  if (stored.expires_at && Date.parse(stored.expires_at) <= Date.now()) {
    await env[KV_BINDING_NAME].delete(pairKey(pairingCode));

    return jsonResponse(
      {
        ok: false,
        error: "pairing_code_expired",
        message: "Pairing code has expired",
      },
      400,
    );
  }

  const deviceToken = randomBase64Url(DEVICE_TOKEN_BYTES);

  await env[KV_BINDING_NAME].put(
    deviceKey(deviceToken),
    JSON.stringify({
      chat_id: String(stored.chat_id),
      device_name: deviceName,
      paired_at: new Date().toISOString(),
    }),
  );

  await env[KV_BINDING_NAME].put(
    pairKey(pairingCode),
    JSON.stringify({
      ...stored,
      used: true,
      used_at: new Date().toISOString(),
    }),
    {
      expirationTtl: 60,
    },
  );

  return jsonResponse({
    ok: true,
    device_token: deviceToken,
    message: "paired",
  });
}

async function handleNotify(request, env) {
  const body = await readJson(request);
  const deviceToken = typeof body.device_token === "string" ? body.device_token.trim() : "";
  const filename = sanitizeFilename(body.filename);

  if (!deviceToken) {
    return jsonResponse(
      {
        ok: false,
        error: "missing_device_token",
        message: "device_token is required",
      },
      401,
    );
  }

  const stored = await env[KV_BINDING_NAME].get(deviceKey(deviceToken), { type: "json" });

  if (!stored || !stored.chat_id) {
    return jsonResponse(
      {
        ok: false,
        error: "invalid_device_token",
        message: "device_token is invalid",
      },
      401,
    );
  }

  const escapedFilename = escapeTelegramHtml(filename || "render");

  await sendTelegramMessage(env, {
    chatId: stored.chat_id,
    text: `<b>${escapedFilename}</b> finished ✅`,
    parseMode: "HTML",
  });

  return jsonResponse({
    ok: true,
    sent: true,
  });
}

async function sendTelegramMessage(env, options) {
  const token = env.TELEGRAM_BOT_TOKEN;
  const chatId = options.chatId;
  const text = options.text;
  const parseMode = options.parseMode;
  const replyMarkup = options.replyMarkup;

  if (!token) {
    throw new Error("Missing TELEGRAM_BOT_TOKEN secret");
  }

  const payload = {
    chat_id: String(chatId),
    text,
    disable_web_page_preview: true,
  };

  if (parseMode) {
    payload.parse_mode = parseMode;
  }

  if (replyMarkup) {
    payload.reply_markup = replyMarkup;
  }

  const response = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  const result = await response.json().catch(() => null);

  if (!response.ok || !result || result.ok !== true) {
    throw new Error("Telegram sendMessage failed");
  }

  return result;
}

async function editTelegramMessageText(env, options) {
  const token = env.TELEGRAM_BOT_TOKEN;
  const chatId = options.chatId;
  const messageId = options.messageId;
  const text = options.text;
  const replyMarkup = options.replyMarkup;

  if (!token) {
    throw new Error("Missing TELEGRAM_BOT_TOKEN secret");
  }

  const payload = {
    chat_id: String(chatId),
    message_id: messageId,
    text,
    disable_web_page_preview: true,
  };

  if (replyMarkup) {
    payload.reply_markup = replyMarkup;
  }

  const response = await fetch(`https://api.telegram.org/bot${token}/editMessageText`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  const result = await response.json().catch(() => null);

  if (!response.ok || !result || result.ok !== true) {
    if (isTelegramMessageNotModified(result)) {
      return result;
    }

    throw new Error("Telegram editMessageText failed");
  }

  return result;
}

async function answerCallbackQuery(env, options) {
  const token = env.TELEGRAM_BOT_TOKEN;
  const callbackQueryId = options.callbackQueryId;
  const text = options.text;

  if (!token) {
    throw new Error("Missing TELEGRAM_BOT_TOKEN secret");
  }

  const payload = {
    callback_query_id: callbackQueryId,
  };

  if (text) {
    payload.text = text;
  }

  const response = await fetch(`https://api.telegram.org/bot${token}/answerCallbackQuery`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  const result = await response.json().catch(() => null);

  if (!response.ok || !result || result.ok !== true) {
    throw new Error("Telegram answerCallbackQuery failed");
  }

  return result;
}

function isTelegramMessageNotModified(result) {
  return (
    result &&
    typeof result.description === "string" &&
    result.description.toLowerCase().includes("message is not modified")
  );
}

async function generateUniquePairingCode(env) {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const code = randomAlphanumeric(6);
    const existing = await env[KV_BINDING_NAME].get(pairKey(code));

    if (!existing) {
      return code;
    }
  }

  throw new Error("Could not generate unique pairing code");
}

async function readJson(request) {
  const contentType = request.headers.get("content-type") || "";

  if (!contentType.includes("application/json")) {
    return {};
  }

  return request.json();
}

function jsonResponse(payload, status = 200) {
  return new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
    },
  });
}

function pairKey(pairingCode) {
  return `pair:${pairingCode}`;
}

function deviceKey(deviceToken) {
  return `device:${deviceToken}`;
}

function normalizePairingCode(value) {
  const text = typeof value === "string" ? value.trim().toUpperCase() : "";

  if (!/^[A-Z0-9]{6}$/.test(text)) {
    return "";
  }

  return text;
}

function sanitizeDeviceName(value) {
  const text = typeof value === "string" ? value.trim() : "";

  if (!text) {
    return "";
  }

  return text.slice(0, 80);
}

function sanitizeFilename(value) {
  const text = typeof value === "string" ? value.trim() : "";

  if (!text) {
    return "render";
  }

  const withoutPath = text.split(/[\\/]/).filter(Boolean).pop() || "render";
  const withoutControlChars = withoutPath.replace(/[\u0000-\u001F\u007F]/g, "");
  const compact = withoutControlChars.trim();

  return compact.slice(0, 200) || "render";
}

function escapeTelegramHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function randomAlphanumeric(length) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);

  let result = "";

  for (const byte of bytes) {
    result += alphabet[byte % alphabet.length];
  }

  return result;
}

function randomBase64Url(byteLength) {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);

  let binary = "";

  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function safeErrorMessage(error) {
  const message = error && error.message ? String(error.message) : "Unknown error";

  if (message.includes("TELEGRAM_BOT_TOKEN")) {
    return message;
  }

  if (message.includes("Telegram sendMessage failed")) {
    return message;
  }

  if (message.includes("Telegram editMessageText failed")) {
    return message;
  }

  if (message.includes("Telegram answerCallbackQuery failed")) {
    return message;
  }

  return "Unexpected backend error";
}