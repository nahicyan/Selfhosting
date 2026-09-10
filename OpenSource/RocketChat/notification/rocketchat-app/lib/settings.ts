import type { ISetting } from '@rocket.chat/apps-engine/definition/settings';
import { SettingType } from '@rocket.chat/apps-engine/definition/settings';

export const SettingId = {
	NtfyBaseUrl: 'Ntfy_Base_Url',
	NtfyAuthToken: 'Ntfy_Auth_Token',
	NotifyTargets: 'Notify_Targets',
	IncludeMessagePreview: 'Include_Message_Preview',
	NotifyOnDirectMessage: 'Notify_On_Direct_Message',
	NotifyOnMention: 'Notify_On_Mention',
	RootUrl: 'Root_Url',
	NtfyPriorityDm: 'Ntfy_Priority_Dm',
	NtfyPriorityMention: 'Ntfy_Priority_Mention',
	HaBaseUrl: 'Ha_Base_Url',
	HaLongLivedToken: 'Ha_Long_Lived_Token',
	HaTriggerUsername: 'Ha_Trigger_Username',
	HaTriggerKeyword: 'Ha_Trigger_Keyword',
	HaServiceDomain: 'Ha_Service_Domain',
	HaServiceName: 'Ha_Service_Name',
	HaEntityId: 'Ha_Entity_Id',
} as const;

export function buildSettingsList(): ISetting[] {
	return [
		{
			id: SettingId.NtfyBaseUrl,
			type: SettingType.STRING,
			packageValue: '',
			required: true,
			public: false,
			section: 'ntfy (Goal One)',
			i18nLabel: 'Ntfy base URL',
			i18nDescription: 'Base URL of your self-hosted ntfy server, e.g. https://ntfy.example.com',
		},
		{
			id: SettingId.NtfyAuthToken,
			type: SettingType.PASSWORD,
			packageValue: '',
			required: false,
			public: false,
			section: 'ntfy (Goal One)',
			i18nLabel: 'Ntfy auth token',
			i18nDescription:
				'Bearer token the App publishes with (ntfy token add <user>). Required if your ntfy server ' +
				'runs with auth-default-access=deny-all - without it publishes are rejected with a 403.',
		},
		{
			id: SettingId.NotifyTargets,
			type: SettingType.STRING,
			packageValue: '',
			required: true,
			public: false,
			multiline: true,
			section: 'ntfy (Goal One)',
			i18nLabel: 'Notify targets',
			i18nDescription:
				'One "user:ntfy_topic" pair per line (or comma separated). "user" is either a Rocket.Chat username ' +
				'(case-insensitive), e.g. nathan:nathan-rc-alerts, or a Rocket.Chat user id, e.g. opAcMbaeD8Bxr8JpD:nathan-rc-alerts. ' +
				'Prefer the user id: usernames have to be learned from the message stream first (they resolve as soon as that ' +
				'person sends any message), while an id matches immediately and needs no lookups at all.',
		},
		{
			id: SettingId.NotifyOnDirectMessage,
			type: SettingType.BOOLEAN,
			packageValue: true,
			required: false,
			public: false,
			section: 'ntfy (Goal One)',
			i18nLabel: 'Notify on direct messages',
		},
		{
			id: SettingId.NotifyOnMention,
			type: SettingType.BOOLEAN,
			packageValue: true,
			required: false,
			public: false,
			section: 'ntfy (Goal One)',
			i18nLabel: 'Notify on @mentions',
		},
		{
			id: SettingId.IncludeMessagePreview,
			type: SettingType.BOOLEAN,
			packageValue: true,
			required: false,
			public: false,
			section: 'ntfy (Goal One)',
			i18nLabel: 'Include message text in the notification',
			i18nDescription: 'Disable to only show "New message" (e.g. if the ntfy notification is visible on your lock screen)',
		},
		{
			id: SettingId.NtfyPriorityDm,
			type: SettingType.NUMBER,
			packageValue: 4,
			required: false,
			public: false,
			section: 'ntfy (Goal One)',
			i18nLabel: 'Ntfy priority for direct messages (1-5)',
		},
		{
			id: SettingId.NtfyPriorityMention,
			type: SettingType.NUMBER,
			packageValue: 3,
			required: false,
			public: false,
			section: 'ntfy (Goal One)',
			i18nLabel: 'Ntfy priority for @mentions (1-5)',
		},
		{
			id: SettingId.RootUrl,
			type: SettingType.STRING,
			packageValue: '',
			required: false,
			public: false,
			section: 'ntfy (Goal One)',
			i18nLabel: 'Rocket.Chat root URL',
			i18nDescription: 'Same value as your ROOT_URL env var. Used to build a deep link back into Rocket.Chat from the notification',
		},
		{
			id: SettingId.HaBaseUrl,
			type: SettingType.STRING,
			packageValue: '',
			required: false,
			public: false,
			section: 'Home Assistant (Goal Two)',
			i18nLabel: 'Home Assistant base URL',
			i18nDescription: 'e.g. https://homeassistant.example.com. Leave empty to disable Goal Two entirely',
		},
		{
			id: SettingId.HaLongLivedToken,
			type: SettingType.PASSWORD,
			packageValue: '',
			required: false,
			public: false,
			section: 'Home Assistant (Goal Two)',
			i18nLabel: 'Home Assistant long-lived access token',
		},
		{
			id: SettingId.HaTriggerUsername,
			type: SettingType.STRING,
			packageValue: '',
			required: false,
			public: false,
			section: 'Home Assistant (Goal Two)',
			i18nLabel: 'Trigger username',
			i18nDescription:
				'Rocket.Chat username (case-insensitive) or user id whose direct messages trigger the Home Assistant action',
		},
		{
			id: SettingId.HaTriggerKeyword,
			type: SettingType.STRING,
			packageValue: '',
			required: false,
			public: false,
			section: 'Home Assistant (Goal Two)',
			i18nLabel: 'Trigger keyword (optional)',
			i18nDescription: 'Only trigger when the DM text contains this word. Leave empty to trigger on every DM from the trigger username',
		},
		{
			id: SettingId.HaServiceDomain,
			type: SettingType.STRING,
			packageValue: 'light',
			required: false,
			public: false,
			section: 'Home Assistant (Goal Two)',
			i18nLabel: 'Service domain',
			i18nDescription: 'e.g. light, switch, script',
		},
		{
			id: SettingId.HaServiceName,
			type: SettingType.STRING,
			packageValue: 'turn_on',
			required: false,
			public: false,
			section: 'Home Assistant (Goal Two)',
			i18nLabel: 'Service name',
			i18nDescription: 'e.g. turn_on, turn_off, toggle',
		},
		{
			id: SettingId.HaEntityId,
			type: SettingType.STRING,
			packageValue: '',
			required: false,
			public: false,
			section: 'Home Assistant (Goal Two)',
			i18nLabel: 'Entity ID',
			i18nDescription: 'e.g. light.living_room',
		},
	];
}

export function parseNotifyTargets(raw: string | undefined): Map<string, string> {
	const targets = new Map<string, string>();

	if (!raw) {
		return targets;
	}

	raw
		.split(/[\n,]/)
		.map((entry) => entry.trim())
		.filter(Boolean)
		.forEach((entry) => {
			const [username, topic] = entry.split(':').map((part) => part?.trim());
			if (username && topic) {
				targets.set(username, topic);
			}
		});

	return targets;
}
