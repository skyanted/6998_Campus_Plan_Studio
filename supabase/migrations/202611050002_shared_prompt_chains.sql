begin;
alter table private.week7_steps add column model_id bigint references private.week7_models,add column format text not null default 'json' check(format in ('text','json')),add column use_app_context boolean not null default true;
alter table private.studio_runs add column shared_chain_id bigint references private.week7_chains on delete set null;
alter table private.week7_responses drop constraint week7_responses_step_id_fkey,add constraint week7_responses_step_id_fkey foreign key(step_id) references private.week7_steps on delete set null;
alter table private.week7_requests drop constraint week7_requests_chain_id_fkey,add constraint week7_requests_chain_id_fkey foreign key(chain_id) references private.week7_chains on delete set null;
alter table private.week7_responses add column step_index integer,add column system_message text;
create unique index week8_response_order on private.week7_responses(request_id,step_index) where step_index is not null;
create function private.studio_context() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('source','Admin','rules',(select template from private.week7_app_rules where id=1),'terms',(select coalesce(jsonb_agg(jsonb_build_object('term',t.term,'definition',t.definition) order by t.id),'[]') from (select * from private.week7_terms where enabled order by id limit 30)t),'examples',(select coalesce(jsonb_agg(jsonb_build_object('input',e.input,'output',e.output) order by e.id),'[]') from (select * from private.week7_examples where enabled order by id limit 5)e),'covers',(select coalesce(jsonb_agg(jsonb_build_object('id',cv.id,'description',cv.description) order by cv.id),'[]') from public.week4_covers cv));
$$;
create function private.studio_revision(cid bigint) returns text language sql stable security definer set search_path='' as $$select md5((to_jsonb(c)||jsonb_build_object('steps',(select coalesce(jsonb_agg(to_jsonb(st) order by st.position),'[]') from private.week7_steps st where st.chain_id=c.id)))::text) from private.week7_chains c where c.id=cid$$;
create function private.studio_snapshot(cid bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$declare result jsonb;begin
 select jsonb_agg(to_jsonb(st)||jsonb_build_object('model_id',m.id,'model',m.identifier,'adapter',v.adapter,'provider',v.name,'credential_env',v.credential_env,'assembly',case when st.use_app_context then private.studio_context() else null end) order by st.position) into result from private.week7_steps st join private.week7_models m on m.id=coalesce(st.model_id,(select model_id from private.week7_generation_settings where id=1)) join private.week7_providers v on v.id=m.provider_id where st.chain_id=cid and m.enabled and v.enabled and v.adapter='gemini';
 if result is null or jsonb_array_length(result)<>(select count(*) from private.week7_steps where chain_id=cid) then raise exception 'Add steps and select enabled models.';end if;return result;
end$$;
revoke all on function private.studio_context(),private.studio_revision(bigint),private.studio_snapshot(bigint) from public,anon,authenticated;
-- Preserve the first Studio draft and any runs while sharing the existing chain catalog.
do $$declare draft record;cid bigint;begin
 for draft in select * from private.studio_chains loop
 insert into private.week7_chains(name,description) values(draft.name,draft.description) returning id into cid;
 insert into private.week7_steps(chain_id,position,name,instructions,model_id,format,use_app_context) select cid,position,name,replace(instructions,'Return JSON with title, description, suggested_location, duration_minutes and estimated_budget.','Follow the activity JSON schema in App rules.'),model_id,format,position=(select max(position) from private.studio_steps where chain_id=draft.id) from private.studio_steps where chain_id=draft.id order by position;
 insert into private.week7_mix(chain_id,weight) values(cid,0);
 update private.studio_runs set shared_chain_id=cid where chain_id=draft.id;
 end loop;
end$$;
create or replace function public.studio_command(action text,p jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare c private.week7_chains;r private.studio_runs;s jsonb;steps jsonb;idx integer:=0;sid bigint;seen bigint[]:='{}';
begin
perform private.week6_assert_superadmin();
if action='list' then
 return jsonb_build_object('chains',(select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]') from (select cl.*,private.studio_revision(cl.id) revision,(select weight from private.week7_mix where chain_id=cl.id) weight,(select coalesce(jsonb_agg(to_jsonb(st) order by st.position),'[]') from private.week7_steps st where st.chain_id=cl.id) steps from private.week7_chains cl)x),'models',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'identifier',m.identifier)),'[]') from private.week7_models m join private.week7_providers v on v.id=m.provider_id where m.enabled and v.enabled and v.adapter='gemini'),'context',private.studio_context());
elsif action='save' then
 perform pg_advisory_xact_lock(729100);
 if length(btrim(coalesce(p->>'name',''))) not between 1 and 100 or length(coalesce(p->>'description',''))>1000 or jsonb_typeof(p->'steps') is distinct from 'array' or jsonb_array_length(p->'steps')>10 then raise exception 'Check the chain name and steps (maximum 10).';end if;
 if p->>'id' is null then insert into private.week7_chains(name,description) values(btrim(p->>'name'),coalesce(p->>'description','')) returning * into c;insert into private.week7_mix(chain_id,weight) values(c.id,0);
 else select * into c from private.week7_chains where id=(p->>'id')::bigint for update;
 if c.id is null or private.studio_revision(c.id) is distinct from p->>'revision' then raise exception 'Chain changed. Reload before saving.';end if;
 if exists(select 1 from private.week7_mix where chain_id=c.id and weight>0) and (jsonb_array_length(p->'steps')=0 or p->'steps'->-1->>'format' is distinct from 'json' or p->'steps'->-1->>'use_app_context' is distinct from 'true') then raise exception 'Active Campus Plans chains must end with JSON and App context enabled.';end if;
 update private.week7_chains set name=btrim(p->>'name'),description=coalesce(p->>'description','') where id=c.id;
 end if;
 update private.week7_steps set position=position+100000 where chain_id=c.id;
 for s in select value from jsonb_array_elements(p->'steps') loop
 idx:=idx+1;
 if length(btrim(coalesce(s->>'name',''))) not between 1 and 100 or length(btrim(coalesce(s->>'instructions',''))) not between 1 and 10000 or coalesce(s->>'format','') not in ('text','json') then raise exception 'Each step needs a name, prompt and output format.';end if;
 if nullif(s->>'model_id','') is not null and not exists(select 1 from private.week7_models m join private.week7_providers v on v.id=m.provider_id where m.id=(s->>'model_id')::bigint and m.enabled and v.enabled and v.adapter='gemini') then raise exception 'Select an enabled model.';end if;
 sid:=nullif(s->>'id','')::bigint;
 if sid is not null then
 if sid=any(seen) or not exists(select 1 from private.week7_steps where id=sid and chain_id=c.id) then raise exception 'Step no longer belongs to this chain.';end if;
 update private.week7_steps set position=idx,name=btrim(s->>'name'),instructions=btrim(s->>'instructions'),model_id=nullif(s->>'model_id','')::bigint,format=s->>'format',use_app_context=coalesce((s->>'use_app_context')::boolean,false) where id=sid;
 else insert into private.week7_steps(chain_id,position,name,instructions,model_id,format,use_app_context) values(c.id,idx,btrim(s->>'name'),btrim(s->>'instructions'),nullif(s->>'model_id','')::bigint,s->>'format',coalesce((s->>'use_app_context')::boolean,false)) returning id into sid;end if;
 seen:=array_append(seen,sid);
 end loop;
 delete from private.week7_steps where chain_id=c.id and not(id=any(seen));
 return jsonb_build_object('id',c.id,'revision',private.studio_revision(c.id));
elsif action='delete' then
 perform pg_advisory_xact_lock(729100);select * into c from private.week7_chains where id=(p->>'id')::bigint for update;
 if c.id is null or private.studio_revision(c.id) is distinct from p->>'revision' then raise exception 'Chain changed. Reload before deleting.';end if;
 if exists(select 1 from private.week7_mix where chain_id=c.id and weight>0) then raise exception 'Remove this chain from the active mix in Admin before deleting it.';end if;
 delete from private.week7_mix where chain_id=c.id;delete from private.week7_steps where chain_id=c.id;delete from private.week7_chains where id=c.id;return '{}';
elsif action='runs' then
 return (select coalesce(jsonb_agg(to_jsonb(rr) order by rr.created_at desc),'[]') from (select id,shared_chain_id,snapshot->>'name' name,status,created_at,error,jsonb_array_length(results) completed_steps from private.studio_runs where shared_chain_id=(p->>'id')::bigint order by created_at desc limit 50)rr);
elsif action='run' then
 select * into r from private.studio_runs where id=(p->>'id')::uuid;if r.id is null then raise exception 'Run not found.';end if;return to_jsonb(r);
elsif action='start' then
 perform pg_advisory_xact_lock(729100);select * into c from private.week7_chains where id=(p->>'id')::bigint for share;
 if c.id is null or private.studio_revision(c.id) is distinct from p->>'revision' then raise exception 'Chain changed. Reload before running.';end if;
 if length(coalesce(p->'input'->>'text',''))>12000 or length(coalesce(p->'input'->>'image',''))>2900000 or (coalesce(p->'input'->>'text','')='' and coalesce(p->'input'->>'image','')='') then raise exception 'Enter text or upload an image.';end if;
 steps:=private.studio_snapshot(c.id);
 insert into private.studio_runs(shared_chain_id,created_by,snapshot,input) values(c.id,auth.uid(),to_jsonb(c)||jsonb_build_object('steps',steps),p->'input') returning * into r;return to_jsonb(r);
elsif action='claim' then
 select * into r from private.studio_runs where id=(p->>'id')::uuid for update;
 if r.status='running' and r.started_at<now()-interval '2 minutes' then update private.studio_runs set status='failed',error='Execution interrupted. Start a new run.' where id=r.id returning * into r;return to_jsonb(r);end if;
 if r.id is null or r.status<>'ready' then raise exception 'Run is not ready.';end if;
 update private.studio_runs set status='running',claim=gen_random_uuid(),started_at=now() where id=r.id returning * into r;return to_jsonb(r);
elsif action='finish' then
 select * into r from private.studio_runs where id=(p->>'id')::uuid for update;
 if r.id is null or r.status<>'running' or r.claim is distinct from (p->>'claim')::uuid then raise exception 'Execution no longer matches.';end if;
 update private.studio_runs set results=results||jsonb_build_array(p->'result'),status=case when p->>'error' is not null then 'failed' when jsonb_array_length(results)+1=jsonb_array_length(snapshot->'steps') then 'completed' else 'ready' end,error=left(p->>'error',1000),claim=null where id=r.id returning * into r;return to_jsonb(r);
end if;
raise exception 'Unknown action.';
end$$;

create function public.week8_pipeline(p_gid bigint,p_proof text default null,p_source text default 'consumer') returns jsonb language plpgsql security definer set search_path='' as $$declare config jsonb;steps jsonb;begin
 perform private.week7_runtime_guard(p_proof);perform pg_advisory_xact_lock(729100);
 config:=private.week7_pipeline(p_gid,p_proof,p_source);steps:=private.studio_snapshot((config->>'chain_id')::bigint);
 config:=config||jsonb_build_object('steps',steps,'chain_name',(select name from private.week7_chains where id=(config->>'chain_id')::bigint));
 update private.week7_requests set snapshot=config where id=(config->>'request_id')::bigint;return config;
end$$;
create function public.week8_record_response(p_request bigint,p_index integer,p_response jsonb,p_proof text default null) returns void language plpgsql security definer set search_path='' as $$declare req private.week7_requests;st jsonb;sid bigint;mid bigint;begin
 perform private.week7_runtime_guard(p_proof);
 select * into req from private.week7_requests where id=p_request and user_id=auth.uid() and status='pending' for update;
 if req.id is null or p_index is null or p_index<0 or p_index>=jsonb_array_length(req.snapshot->'steps') or p_index<>(select count(*) from private.week7_responses where request_id=req.id) then raise exception 'Step is unavailable or already recorded.';end if;
 if exists(select 1 from private.week7_responses where request_id=req.id and error is not null) then raise exception 'A previous step failed.';end if;
 if length(p_response::text)>1000000 or length(p_response->>'prompt')>60000 then raise exception 'Response too large.';end if;
 st:=req.snapshot->'steps'->p_index;select id into sid from private.week7_steps where id=(st->>'id')::bigint;select id into mid from private.week7_models where id=(st->>'model_id')::bigint;
 insert into private.week7_responses(request_id,step_id,step_index,model_id,model,provider,prompt,system_message,response_text,response_json,raw_response,usage,latency_ms,http_status,error,source) values(req.id,sid,p_index,mid,st->>'model',st->>'provider',p_response->>'prompt',p_response->>'system',p_response->>'text',p_response->'json',p_response->'raw',p_response->'usage',(p_response->>'latency_ms')::integer,(p_response->>'http_status')::integer,left(p_response->>'error',1000),'live');
 update public.week4_ai_generations set prompt=left(p_response->>'prompt',20000),model=st->>'model' where id=req.generation_id;
end$$;
revoke all on function public.week8_pipeline(bigint,text,text),public.week8_record_response(bigint,integer,jsonb,text) from public,anon;
grant execute on function public.week8_pipeline(bigint,text,text),public.week8_record_response(bigint,integer,jsonb,text) to authenticated;

create function private.week8_validate_mix() returns trigger language plpgsql security definer set search_path='' as $$declare last_step private.week7_steps;begin
 if new.weight>0 then
 select * into last_step from private.week7_steps where chain_id=new.chain_id order by position desc limit 1;
 if last_step.id is null or last_step.format<>'json' or not last_step.use_app_context then raise exception 'The final step needs JSON output and App context before using this chain in Campus Plans.';end if;
 end if;return new;
end$$;
revoke all on function private.week8_validate_mix() from public,anon,authenticated;
create trigger week8_validate_mix before insert or update of weight on private.week7_mix for each row execute function private.week8_validate_mix();

notify pgrst,'reload schema';
commit;
