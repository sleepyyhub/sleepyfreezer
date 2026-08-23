import { config } from './config.js';

/**
 * Ruft OpenRouter im OpenAI-kompatiblen /chat/completions Format auf.
 * Bei 429/5xx wird mit exponentiellem Backoff bis zu 3x wiederholt.
 */
export async function chat(messages, { signal } = {}) {
  const maxAttempts = 3;
  let lastError;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    if (attempt > 0) {
      await new Promise((r) => setTimeout(r, 2 ** attempt * 500));
    }

    let response;
    try {
      response = await fetch(`${config.baseUrl}/chat/completions`, {
        method: 'POST',
        signal,
        headers: {
          Authorization: `Bearer ${config.openRouterKey}`,
          'Content-Type': 'application/json',
          'X-Title': 'sleepyfreezer-bot',
        },
        body: JSON.stringify({
          model: config.model,
          messages,
          max_tokens: config.maxTokens,
          temperature: config.temperature,
        }),
      });
    } catch (err) {
      lastError = err;
      continue;
    }

    if (response.status === 429 || response.status >= 500) {
      lastError = new Error(`OpenRouter ${response.status}: ${await response.text()}`);
      continue;
    }

    if (!response.ok) {
      throw new Error(`OpenRouter ${response.status}: ${await response.text()}`);
    }

    const data = await response.json();
    const content = data?.choices?.[0]?.message?.content;
    if (!content) {
      throw new Error(`Leere Antwort von OpenRouter: ${JSON.stringify(data).slice(0, 400)}`);
    }
    return content.trim();
  }

  throw lastError ?? new Error('OpenRouter: unbekannter Fehler');
}
