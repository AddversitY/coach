// Public status is an allowlist. Provider errors and private usage records never
// become user-facing text or prompts.
const messages={
 disabled:'Scheduled sportsbook price updates are disabled.',
 missing_key:'The price connection needs its server credential restored.',
 identity_unavailable:'Prices are withheld until player identities can be verified.',
 publication_running:'A scheduled price update is already running.',
 ledger_unavailable:'Price updates are paused while the private usage checkpoint is recovered.',
 daily_limit:'The free daily price-update allowance has been used.',
 monthly_limit:'The free monthly price-update allowance has been used.',
 no_upcoming_game:'There are no upcoming NFL games in the current schedule.',
 waiting_window:'Prices are waiting for the scheduled pregame update window.',
 usage_review:'Price updates are paused for a provider-usage check.',
 protected_reserve:'Price updates are paused to preserve the free provider allowance.',
 event_unmatched:'The provider has no verified match for an upcoming game.',
 no_valid_quotes:'The provider returned no usable exact-selection prices.',
 source_unavailable:'The scheduled price update could not be completed. Saved prices have not been refreshed.',
};
export function priceAvailability(snapshot,now=Date.now()){
 const a=snapshot?.odds?.availability;
 if(snapshot?.odds?.status!=='unavailable'||snapshot.odds.provider!=='the-odds-api'||!a||!Object.hasOwn(messages,a.reason))return null;
 const checked=Date.parse(a.checkedAt),eligible=Date.parse(a.eligibleAt);
 if(!Number.isFinite(checked)||checked>now+5000||now-checked>86400000)return null;
 const result={reason:a.reason,checkedAt:new Date(checked).toISOString(),message:messages[a.reason]};
 if(['waiting_window','daily_limit','monthly_limit'].includes(a.reason)&&Number.isFinite(eligible)&&eligible>checked&&eligible-checked<=32*86400000){
  result.eligibleAt=new Date(eligible).toISOString();
  result.message+=eligible>now?` Next eligible window: ${new Intl.DateTimeFormat('en-US',{timeZone:'America/New_York',month:'short',day:'numeric',hour:'numeric',minute:'2-digit',timeZoneName:'short'}).format(new Date(eligible))}. This is eligibility, not a promised refresh time.`:' The eligibility time has passed; a successful scheduled update is still needed.';
 }
 return result;
}
