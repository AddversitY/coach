export function aiFailure(error){
 const message=String(error?.message||error||'');
 if(/3036|4006|daily.*(?:allocation|neurons)|free.*allocation/i.test(message))return 'provider_daily_limit';
 if(/3040|capacity/i.test(message))return 'provider_capacity';
 if(/5035|paid plan|upgrade/i.test(message))return 'model_requires_paid_plan';
 if(/schema|invalid.*(?:input|request)|400\b/i.test(message))return 'invalid_model_request';
 if(/Invalid.*(?:model|explanation|benchmark)|Missing evidence|JSON|parse/i.test(message))return 'invalid_model_reply';
 if(/timeout|abort|deadline/i.test(message))return 'provider_timeout';
 if(/401|403|unauth|permission/i.test(message))return 'provider_access';
 return 'provider_unavailable';
}
