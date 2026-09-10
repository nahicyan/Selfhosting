function escapeRegExp(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Best-effort detection of an "@username" mention inside raw message text.
 * Rocket.Chat's apps-engine IMessage does not expose a parsed mentions array,
 * so we match the same literal "@username" pattern the composer inserts.
 *
 * Case-insensitive: Rocket.Chat usernames are unique case-insensitively (you can't have
 * both "nathan" and "Nathan" as separate accounts), so treat them as equivalent here too.
 */
export function isUserMentioned(text: string, username: string): boolean {
	if (!text || !username) {
		return false;
	}

	const pattern = new RegExp(`(^|[^a-zA-Z0-9_.])@${escapeRegExp(username)}(?![a-zA-Z0-9_.])`, 'i');
	return pattern.test(text);
}

export function isAllOrHereMentioned(text: string): boolean {
	if (!text) {
		return false;
	}

	return /(^|[^a-zA-Z0-9_.])@(all|here)(?![a-zA-Z0-9_.])/.test(text);
}
