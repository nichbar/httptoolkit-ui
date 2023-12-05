import * as localForage from 'localforage';

import { RUNNING_IN_WORKER } from '../util';
import { delay, getDeferred } from '../util/promise';
import {
    versionSatisfies,
    SERVER_REST_API_SUPPORTED
} from './service-versions';

import { type ServerConfig, type NetworkInterfaces, type ServerInterceptor, ApiError } from './server-api-types';
export { ServerConfig, NetworkInterfaces, ServerInterceptor };

import { GraphQLApiClient } from './server-graphql-api';
import { RestApiClient } from './server-rest-api';
import { RequestDefinition, RequestOptions } from '../model/send/send-request-model';

const authTokenPromise = !RUNNING_IN_WORKER
    // Main UI gets given the auth token directly in its URL:
    ? Promise.resolve(new URLSearchParams(window.location.search).get('authToken') ?? undefined)
    // For workers, the new (March 2020) UI shares the auth token with SW via IDB:
    : localForage.getItem<string>('latest-auth-token')
        .then((authToken) => {
            if (authToken) return authToken;

            // Old UI (Jan-March 2020) shares auth token via SW query param:
            const workerParams = new URLSearchParams(
                (self as unknown as WorkerGlobalScope).location.search
            );
            return workerParams.get('authToken') ?? undefined;

            // Pre-Jan 2020 UI doesn't share auth token - ok with old desktop, fails with 0.1.18+.
        });

const serverReady = getDeferred();
export const announceServerReady = () => serverReady.resolve();
export const waitUntilServerReady = () => serverReady.promise;

const apiClient: Promise<GraphQLApiClient | RestApiClient> = authTokenPromise.then(async (authToken) => {
    await waitUntilServerReady();

    const restClient = new RestApiClient(authToken);
    const graphQLClient = new GraphQLApiClient(authToken);

    // To work out which API is supported, we loop trying to get the version from
    // each one (may take a couple of tries as the server starts up), and then
    // check the resulting version to see what's supported.

    let version: string | undefined;
    while (!version) {
        version = await restClient.getServerVersion().catch(() => {
            console.log("Couldn't get version from REST API");

            return graphQLClient.getServerVersion().catch(() => {
                console.log("Couldn't get version from GraphQL API");
                return undefined;
            });
        });

        if (!version) await delay(100);
    }

    if (versionSatisfies(version, SERVER_REST_API_SUPPORTED)) {
        return restClient;
    } else {
        return graphQLClient;
    }
});

export async function getServerVersion(): Promise<string> {
    return (await apiClient).getServerVersion();
}

export async function getConfig(proxyPort: number): Promise<ServerConfig> {
    return (await apiClient).getConfig(proxyPort);
}

export async function getNetworkInterfaces(): Promise<NetworkInterfaces> {
    return (await apiClient).getNetworkInterfaces();
}

export async function getInterceptors(proxyPort: number): Promise<ServerInterceptor[]> {
    return (await apiClient).getInterceptors(proxyPort);
}

export async function getDetailedInterceptorMetadata<M extends unknown>(id: string): Promise<M | undefined> {
    return (await apiClient).getDetailedInterceptorMetadata(id);
}

export async function activateInterceptor(id: string, proxyPort: number, options?: any): Promise<unknown> {
    const result = await (await apiClient).activateInterceptor(id, proxyPort, options);

    if (result.success) {
        return result.metadata;
    } else {
        // Some kind of failure:
        console.log('Activation result', JSON.stringify(result));

        const error = Object.assign(
            new ApiError(`failed to activate interceptor ${id}`, `activate-interceptor-${id}`),
            result
        );

        throw error;
    }
}

export async function sendRequest(
    requestDefinition: RequestDefinition,
    requestOptions: RequestOptions
) {
    const client = (await apiClient);
    if (!(client instanceof RestApiClient)) {
        throw new Error("Requests cannot be sent via the GraphQL API client");
    }

    return client.sendRequest(requestDefinition, requestOptions);
}

export async function triggerServerUpdate() {
    return (await apiClient).triggerServerUpdate()
        // We ignore all errors, this trigger is just advisory
        .catch(console.log);
}
