import type { IHttp } from '@rocket.chat/apps-engine/definition/accessors';

export interface HomeAssistantCallOptions {
	baseUrl: string;
	longLivedToken: string;
	domain: string;
	service: string;
	entityId?: string;
}

/**
 * Calls a Home Assistant service via its REST API.
 * See: https://developers.home-assistant.io/docs/api/rest/
 */
export async function callHomeAssistantService(http: IHttp, options: HomeAssistantCallOptions): Promise<void> {
	const { baseUrl, longLivedToken, domain, service, entityId } = options;

	if (!baseUrl || !longLivedToken || !domain || !service) {
		return;
	}

	const url = `${baseUrl.replace(/\/+$/, '')}/api/services/${encodeURIComponent(domain)}/${encodeURIComponent(service)}`;

	const response = await http.post(url, {
		headers: {
			'Content-Type': 'application/json',
			Authorization: `Bearer ${longLivedToken}`,
		},
		content: JSON.stringify(entityId ? { entity_id: entityId } : {}),
	});

	// As with ntfy: http.post resolves for error responses too, so check before claiming success.
	const status = response?.statusCode ?? 0;

	if (status < 200 || status >= 300) {
		const body = typeof response?.content === 'string' ? response.content.slice(0, 500) : '';
		const hint = status === 401 || status === 403 ? ' - check the long-lived access token.' : '';

		throw new Error(`Home Assistant ${domain}.${service} call failed with HTTP ${status}${hint}${body ? ` Response: ${body}` : ''}`);
	}
}
