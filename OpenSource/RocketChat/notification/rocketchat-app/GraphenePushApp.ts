import type {
	IAppAccessors,
	IConfigurationExtend,
	IHttp,
	ILogger,
	IModify,
	IPersistence,
	IRead,
} from '@rocket.chat/apps-engine/definition/accessors';
import { App } from '@rocket.chat/apps-engine/definition/App';
import type { IAppInfo } from '@rocket.chat/apps-engine/definition/metadata';
import type { IMessage, IPostMessageSent } from '@rocket.chat/apps-engine/definition/messages';
import { RoomType } from '@rocket.chat/apps-engine/definition/rooms';
import type {
	IPostUserCreated,
	IPostUserLoggedIn,
	IPostUserStatusChanged,
	IPostUserUpdated,
	IUser,
	IUserContext,
	IUserStatusContext,
} from '@rocket.chat/apps-engine/definition/users';

import { callHomeAssistantService } from './lib/homeAssistant';
import { createDirectory, idFor, knownCount, loadDirectory, rememberUser, usernameFor, type UserDirectory } from './lib/identity';
import { isUserMentioned } from './lib/mentions';
import { publishToNtfy } from './lib/ntfy';
import { buildSettingsList, parseNotifyTargets, SettingId } from './lib/settings';

type NotifyConfig = {
	ntfyBaseUrl: string;
	ntfyAuthToken?: string;
	targets: Map<string, string>;
	includeMessagePreview: boolean;
	notifyOnDirectMessage: boolean;
	notifyOnMention: boolean;
	rootUrl?: string;
	priorityDm: number;
	priorityMention: number;
};

export class GraphenePushApp
	extends App
	implements IPostMessageSent, IPostUserLoggedIn, IPostUserStatusChanged, IPostUserCreated, IPostUserUpdated
{
	/**
	 * username <-> id map, cached in memory for the lifetime of the app instance and backed by
	 * the App's own persistence. See lib/identity.ts for why this exists.
	 */
	private readonly directory: UserDirectory = createDirectory();

	constructor(info: IAppInfo, logger: ILogger, accessors: IAppAccessors) {
		super(info, logger, accessors);
	}

	protected async extendConfiguration(configuration: IConfigurationExtend): Promise<void> {
		await Promise.all(buildSettingsList().map((setting) => configuration.settings.provideSetting(setting)));

		// `/graphene-push` - registers the caller immediately. SlashCommandContext.getSender()
		// carries a full IUser with the event, so this works even where user lookups are broken.
		// Declared inline rather than as an imported class: the packaging step instantiates the
		// App to introspect it, and cross-module classes are not reliably constructible there.
		await configuration.slashCommands.provideSlashCommand({
			command: 'graphene-push',
			i18nParamsExample: '',
			i18nDescription: 'Register yourself with GraphenePush so notifications can find you',
			providesPreview: false,
			executor: async (context, read, modify, _http, persistence): Promise<void> => {
				const sender = context.getSender();

				await this.learn(persistence, sender);

				const text = [
					'*GraphenePush* — you are registered.',
					`• username: \`${sender.username}\``,
					`• user id: \`${sender.id}\``,
					'',
					`Use \`${sender.username}:<your-ntfy-topic>\` in the App's *Notify targets* setting.`,
				].join('\n');

				try {
					const builder = modify.getCreator().startMessage().setRoom(context.getRoom()).setSender(sender).setText(text);

					await read.getNotifier().notifyUser(sender, builder.getMessage());
				} catch {
					// Registration already succeeded; failing to echo it back is not fatal.
				}
			},
		});
	}

	// ---------------------------------------------------------------------------------------
	// Identity learning
	//
	// Every handler below exists purely to record a username <-> id pairing from an event that
	// carries a full IUser. Together they cover: anyone who sends a message, logs in, goes
	// online/away/busy/offline, is created, or is renamed - so a username-configured target
	// becomes resolvable on its own, without any user-lookup bridge call ever succeeding.
	// ---------------------------------------------------------------------------------------

	public async executePostUserLoggedIn(user: IUser, _read: IRead, _http: IHttp, persistence: IPersistence): Promise<void> {
		await this.learn(persistence, user);
	}

	public async executePostUserStatusChanged(
		context: IUserStatusContext,
		_read: IRead,
		_http: IHttp,
		persistence: IPersistence,
	): Promise<void> {
		await this.learn(persistence, context.user);
	}

	public async executePostUserCreated(context: IUserContext, _read: IRead, _http: IHttp, persistence: IPersistence): Promise<void> {
		await this.learn(persistence, context.user);
	}

	public async executePostUserUpdated(context: IUserContext, _read: IRead, _http: IHttp, persistence: IPersistence): Promise<void> {
		await this.learn(persistence, context.user);
	}

	private async learn(persistence: IPersistence, user: { id?: string; username?: string }): Promise<void> {
		try {
			await loadDirectory(this.getAccessors().reader.getPersistenceReader(), this.directory);

			if (await rememberUser(persistence, this.directory, user)) {
				this.getLogger().debug('Learned a user identity', { id: user.id, username: user.username });
			}
		} catch (error) {
			// Learning is best-effort: a persistence hiccup must never break message handling.
			this.getLogger().debug('Could not record a user identity', {
				username: user.username,
				error: error instanceof Error ? error.message : String(error),
			});
		}
	}

	// ---------------------------------------------------------------------------------------
	// Notifications
	// ---------------------------------------------------------------------------------------

	public async executePostMessageSent(message: IMessage, read: IRead, http: IHttp, persistence: IPersistence): Promise<void> {
		// Learn from every message before doing anything else - this is the highest-volume
		// identity source, and it must run even for messages we won't notify about.
		await this.learn(persistence, message.sender);

		if (message.type) {
			// system message (user joined/left/etc.) - never notification-worthy
			return;
		}

		const isDirect = message.room.type === RoomType.DIRECT_MESSAGE;

		if (!isDirect && !message.text?.includes('@')) {
			// regular channel chatter: can't be a DM or a mention, nothing more to do
			return;
		}

		const settings = read.getEnvironmentReader().getSettings();

		const [
			ntfyBaseUrl,
			ntfyAuthToken,
			notifyTargetsRaw,
			includeMessagePreview,
			notifyOnDirectMessage,
			notifyOnMention,
			rootUrl,
			priorityDm,
			priorityMention,
			haBaseUrl,
			haToken,
			haTriggerUsername,
			haTriggerKeyword,
			haServiceDomain,
			haServiceName,
			haEntityId,
		] = await Promise.all([
			settings.getValueById(SettingId.NtfyBaseUrl),
			settings.getValueById(SettingId.NtfyAuthToken),
			settings.getValueById(SettingId.NotifyTargets),
			settings.getValueById(SettingId.IncludeMessagePreview),
			settings.getValueById(SettingId.NotifyOnDirectMessage),
			settings.getValueById(SettingId.NotifyOnMention),
			settings.getValueById(SettingId.RootUrl),
			settings.getValueById(SettingId.NtfyPriorityDm),
			settings.getValueById(SettingId.NtfyPriorityMention),
			settings.getValueById(SettingId.HaBaseUrl),
			settings.getValueById(SettingId.HaLongLivedToken),
			settings.getValueById(SettingId.HaTriggerUsername),
			settings.getValueById(SettingId.HaTriggerKeyword),
			settings.getValueById(SettingId.HaServiceDomain),
			settings.getValueById(SettingId.HaServiceName),
			settings.getValueById(SettingId.HaEntityId),
		]);

		try {
			await this.notifyRecipients(message, http, {
				ntfyBaseUrl,
				ntfyAuthToken,
				targets: parseNotifyTargets(notifyTargetsRaw),
				includeMessagePreview,
				notifyOnDirectMessage,
				notifyOnMention,
				rootUrl,
				priorityDm,
				priorityMention,
			});
		} catch (error) {
			this.getLogger().error('Failed to publish ntfy notification', error);
		}

		try {
			await this.maybeTriggerHomeAssistant(message, http, {
				haBaseUrl,
				haToken,
				haTriggerUsername,
				haTriggerKeyword,
				haServiceDomain,
				haServiceName,
				haEntityId,
			});
		} catch (error) {
			this.getLogger().error('Failed to call Home Assistant', error);
		}
	}

	private async notifyRecipients(message: IMessage, http: IHttp, config: NotifyConfig): Promise<void> {
		if (!config.ntfyBaseUrl || config.targets.size === 0) {
			return;
		}

		const { room, sender, text } = message;
		const isDirect = room.type === RoomType.DIRECT_MESSAGE;
		const senderLabel = sender.name || sender.username || 'someone';

		// The other participants of this room, straight off the event payload. room.userIds is
		// populated and correct even where every user-lookup bridge call comes back empty.
		const otherIds = new Set((room.userIds ?? []).filter((id) => id !== sender.id));

		for (const [target, topic] of config.targets) {
			if (this.isSender(target, sender)) {
				continue;
			}

			// A target may be configured as a username or a raw user id; idFor() accepts either.
			const targetId = idFor(this.directory, target);
			const isDmToTarget = isDirect && (otherIds.has(target) || (targetId !== undefined && otherIds.has(targetId)));

			// If the target was configured by id, match mentions against its learned username.
			const mentionName = usernameFor(this.directory, target) ?? target;
			const isMentioned = isUserMentioned(text ?? '', mentionName);

			const shouldNotify = (config.notifyOnDirectMessage && isDmToTarget) || (config.notifyOnMention && isMentioned && !isDmToTarget);

			this.getLogger().debug('notifyRecipients: evaluated target', {
				target,
				resolvedTargetId: targetId ?? null,
				knownIdentities: knownCount(this.directory),
				roomType: room.type,
				senderUsername: sender.username,
				otherIds: [...otherIds],
				isDmToTarget,
				isMentioned,
				shouldNotify,
			});

			if (!shouldNotify) {
				if (isDirect && targetId === undefined && !otherIds.has(target)) {
					this.getLogger().warn(
						`GraphenePush does not know the user "${target}" yet, so this DM could not be matched. ` +
							`It resolves automatically once that person sends a message, logs in or changes status - ` +
							`or immediately if they run the /graphene-push slash command.`,
					);
				}

				continue;
			}

			const title = isDmToTarget ? `DM from ${senderLabel}` : `${senderLabel} mentioned you`;
			const preview = config.includeMessagePreview && text ? text : 'New message';

			// Publish per target in its own try/catch so one failing topic (bad token, typo'd
			// topic, ntfy down) still lets the remaining targets get their notification.
			try {
				await publishToNtfy(http, {
					baseUrl: config.ntfyBaseUrl,
					authToken: config.ntfyAuthToken,
					topic,
					title,
					message: preview,
					priority: isDmToTarget ? config.priorityDm : config.priorityMention,
					clickUrl: this.buildClickUrl(config.rootUrl, room, sender, isDmToTarget),
					tags: isDmToTarget ? ['speech_balloon'] : ['loudspeaker'],
				});

				this.getLogger().debug('notifyRecipients: published to ntfy', { target, topic });
			} catch (error) {
				this.getLogger().error('notifyRecipients: ntfy publish failed', {
					target,
					topic,
					error: error instanceof Error ? error.message : String(error),
				});
			}
		}
	}

	/** Never notify people about their own messages, whether they're configured by username or id. */
	private isSender(target: string, sender: IMessage['sender']): boolean {
		if (target === sender.id) {
			return true;
		}

		// Rocket.Chat usernames are unique case-insensitively, so "nathan" and "Nathan"
		// are the same account even though a plain === isn't.
		if (sender.username && target.toLowerCase() === sender.username.toLowerCase()) {
			return true;
		}

		return idFor(this.directory, target) === sender.id;
	}

	private buildClickUrl(
		rootUrl: string | undefined,
		room: IMessage['room'],
		sender: IMessage['sender'],
		isDirect: boolean,
	): string | undefined {
		if (!rootUrl) {
			return undefined;
		}

		const base = rootUrl.replace(/\/+$/, '');

		if (isDirect && sender.username) {
			return `${base}/direct/${sender.username}`;
		}

		if (room.type === RoomType.CHANNEL && room.slugifiedName) {
			return `${base}/channel/${room.slugifiedName}`;
		}

		if (room.type === RoomType.PRIVATE_GROUP && room.slugifiedName) {
			return `${base}/group/${room.slugifiedName}`;
		}

		return base;
	}

	private async maybeTriggerHomeAssistant(
		message: IMessage,
		http: IHttp,
		config: {
			haBaseUrl: string;
			haToken: string;
			haTriggerUsername?: string;
			haTriggerKeyword?: string;
			haServiceDomain: string;
			haServiceName: string;
			haEntityId?: string;
		},
	): Promise<void> {
		if (!config.haBaseUrl || !config.haToken || !config.haTriggerUsername) {
			return;
		}

		if (message.room.type !== RoomType.DIRECT_MESSAGE) {
			return;
		}

		// Accepts either a username (case-insensitive) or a raw user id, same as Notify_Targets.
		const trigger = config.haTriggerUsername.trim();
		const matchesSender =
			trigger === message.sender.id ||
			(!!message.sender.username && trigger.toLowerCase() === message.sender.username.toLowerCase()) ||
			idFor(this.directory, trigger) === message.sender.id;

		if (!matchesSender) {
			return;
		}

		if (config.haTriggerKeyword && !(message.text ?? '').toLowerCase().includes(config.haTriggerKeyword.toLowerCase())) {
			return;
		}

		await callHomeAssistantService(http, {
			baseUrl: config.haBaseUrl,
			longLivedToken: config.haToken,
			domain: config.haServiceDomain,
			service: config.haServiceName,
			entityId: config.haEntityId,
		});
	}
}
