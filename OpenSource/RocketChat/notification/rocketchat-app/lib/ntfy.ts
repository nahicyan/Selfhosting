import type { IHttp } from '@rocket.chat/apps-engine/definition/accessors';

export interface NtfyPublishOptions {
	baseUrl: string;
	topic: string;
	title: string;
	message: string;
	/** ntfy priority: 1 (min) - 5 (max), 3 is default */
	priority?: number;
	clickUrl?: string;
	tags?: string[];
	authToken?: string;
}

/**
 * Publishes a message using ntfy's JSON publish endpoint (POST to the server root).
 * See: https://docs.ntfy.sh/publish/#publish-as-json
 */
export async function publishToNtfy(http: IHttp, options: NtfyPublishOptions): Promise<void> {
	const { baseUrl, topic, title, message, priority, clickUrl, tags, authToken } = options;

	if (!baseUrl || !topic) {
		return;
	}

	const url = baseUrl.replace(/\/+$/, '');

	const payload: Record<string, unknown> = {
		topic,
		title,
		message,
	};

	if (priority) {
		payload.priority = priority;
	}

	if (clickUrl) {
		payload.click = clickUrl;
	}

	if (tags?.length) {
		payload.tags = tags;
	}

	const headers: Record<string, string> = {
		'Content-Type': 'application/json',
	};

	if (authToken) {
		headers.Authorization = `Bearer ${authToken}`;
	}

	const response = await http.post(url, {
		headers,
		content: JSON.stringify(payload),
	});

	// http.post resolves for *any* response, including 401/403/404, so an unchecked call
	// reports success while ntfy is actually rejecting every publish. Surface it instead.
	const status = response?.statusCode ?? 0;

	if (status < 200 || status >= 300) {
		const body = typeof response?.content === 'string' ? response.content.slice(0, 500) : '';
		const hint =
			status === 401 || status === 403
				? ' - ntfy rejected the credentials. If your server uses auth-default-access=deny-all, set the ' +
					'"Ntfy auth token" setting to a token with write access to this topic (ntfy token add <user>).'
				: '';

		throw new Error(`ntfy publish to topic "${topic}" failed with HTTP ${status}${hint}${body ? ` Response: ${body}` : ''}`);
	}
}
