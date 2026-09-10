import type { IPersistence, IPersistenceRead } from '@rocket.chat/apps-engine/definition/accessors';
import { RocketChatAssociationModel, RocketChatAssociationRecord } from '@rocket.chat/apps-engine/definition/metadata';

/**
 * A username <-> user id map the App builds up for itself.
 *
 * Why this exists: on some Rocket.Chat deployments (apps run in an isolated Deno runtime and talk
 * back to the server over bridges) every user-lookup bridge call - getByUsername(), getById(),
 * getMembers(), getDirectByUsernames() - returns empty for users that provably exist, with no
 * error raised. What is always correct is the IUser delivered *with* an event: message senders,
 * login/status-change events and slash command senders all carry a full id + username.
 *
 * So identities are learned from those events and persisted, which lets a target configured by
 * username be matched with no lookups at all.
 *
 * Kept as plain functions over a plain object on purpose: the packaging step instantiates the App
 * class to introspect it, and a class defined in this module is not reliably constructible there.
 */
export type UserDirectory = {
	/** lowercased username -> user id */
	byUsername: Record<string, string>;
	/** user id -> username (original casing) */
	byId: Record<string, string>;
	loaded: boolean;
};

export function createDirectory(): UserDirectory {
	return { byUsername: {}, byId: {}, loaded: false };
}

function association(): RocketChatAssociationRecord {
	return new RocketChatAssociationRecord(RocketChatAssociationModel.MISC, 'graphene-push-user-directory');
}

/**
 * Loads the map from persistence once per App instance; later calls are free. Callers should treat
 * a failure here as "empty directory" rather than letting it break the event handler.
 */
export async function loadDirectory(persistenceRead: IPersistenceRead, directory: UserDirectory): Promise<void> {
	if (directory.loaded) {
		return;
	}

	const records = (await persistenceRead.readByAssociation(association())) as Array<Partial<UserDirectory>> | undefined;
	const record = records?.[0];

	directory.byUsername = record?.byUsername ?? {};
	directory.byId = record?.byId ?? {};
	directory.loaded = true;
}

/** Resolves a configured target (username or raw user id) to a user id, if known. */
export function idFor(directory: UserDirectory, usernameOrId: string): string | undefined {
	if (directory.byId[usernameOrId]) {
		return usernameOrId;
	}

	return directory.byUsername[usernameOrId.toLowerCase()];
}

/** The username recorded for a user id, if known. */
export function usernameFor(directory: UserDirectory, id: string): string | undefined {
	return directory.byId[id];
}

export function knownCount(directory: UserDirectory): number {
	return Object.keys(directory.byId).length;
}

/**
 * Records a user, persisting only when something actually changed so that learning can run on
 * every event cheaply. Returns whether a write happened.
 */
export async function rememberUser(
	persistence: IPersistence,
	directory: UserDirectory,
	user: { id?: string; username?: string },
): Promise<boolean> {
	const { id, username } = user;

	if (!id || !username) {
		return false;
	}

	const usernameLower = username.toLowerCase();

	if (directory.byUsername[usernameLower] === id && directory.byId[id] === username) {
		return false;
	}

	// On a rename the old username would otherwise keep pointing at this id forever.
	const previousUsername = directory.byId[id];

	if (previousUsername && previousUsername.toLowerCase() !== usernameLower) {
		delete directory.byUsername[previousUsername.toLowerCase()];
	}

	directory.byUsername[usernameLower] = id;
	directory.byId[id] = username;

	await persistence.updateByAssociation(association(), { byUsername: directory.byUsername, byId: directory.byId }, true);

	return true;
}
