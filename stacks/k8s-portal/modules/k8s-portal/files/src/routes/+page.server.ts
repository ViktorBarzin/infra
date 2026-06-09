import type { PageServerLoad } from './$types';
import { readFileSync } from 'fs';

interface UserRole {
	role: string;
	namespaces: string[];
}

export const load: PageServerLoad = async ({ request }) => {
	const email = request.headers.get('x-authentik-email') || 'unknown';
	const username = request.headers.get('x-authentik-username') || 'unknown';
	const groups = request.headers.get('x-authentik-groups') || '';

	// Read user roles from ConfigMap-mounted file
	let userRole: UserRole = { role: 'unknown', namespaces: [] };
	try {
		const usersJson = readFileSync('/config/users.json', 'utf-8');
		const users = JSON.parse(usersJson);
		if (users[email]) {
			userRole = users[email];
		}
	} catch {
		// ConfigMap not mounted or parse error
	}

	return {
		email,
		username,
		groups: groups.split('|').filter(Boolean),
		role: userRole.role,
		namespaces: userRole.namespaces
	};
};
