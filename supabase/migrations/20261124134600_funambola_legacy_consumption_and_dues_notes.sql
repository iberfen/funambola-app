CREATE OR REPLACE FUNCTION public.validate_bonus_use()
 RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO ''
AS $function$
                                    declare
                                      pack_record record;
                                        used_count integer;
                                        begin
                                          select user_id, coalesce(adjusted_sessions,total_sessions) AS total_sessions, expires_at, cancelled_at
                                            into pack_record
                                              from public.bonus_packs
                                                where id = new.pack_id
                                                  for update;

                                                    if not found then
                                                        raise exception 'Funambono no encontrado';
                                                          end if;

                                                            if pack_record.cancelled_at is not null or now() >= pack_record.expires_at then
                                                                raise exception 'Funambono caducado. Contacta con los responsables de Funambola.';
                                                                  end if;

                                                                    select count(*) into used_count
                                                                      from public.bonus_uses
                                                                        where pack_id = new.pack_id;
 used_count := used_count + (select count(*) from public.bonus_daily_uses where pack_id=new.pack_id);

                                                                          if used_count >= pack_record.total_sessions then
                                                                              raise exception 'Funambono agotado. Contacta con los responsables de Funambola.';
                                                                                end if;

                                                                                  if not exists (
                                                                                      select 1 from public.training_participants
                                                                                          where training_id = new.training_id
                                                                                                and user_id = pack_record.user_id
                                                                                                  ) then
                                                                                                      raise exception 'El titular no esta inscrito en este entrenamiento';
                                                                                                        end if;

                                                                                                          return new;
                                                                                                          end;
                                                                                                          $function$;

revoke all on function public.validate_bonus_use() from public, anon, authenticated;

create function public.save_membership(p_id uuid,p_joined date,p_expiry date,p_type text,p_months int,p_expected_updated timestamptz,p_notes text)
returns void language plpgsql security invoker set search_path='' as $fn$
begin
  perform public.save_membership(p_id,p_joined,p_expiry,p_type,p_months,p_expected_updated);
  update public.membership_dues set notes=nullif(btrim(p_notes),'') where user_id=p_id;
end
$fn$;
revoke all on function public.save_membership(uuid,date,date,text,int,timestamptz,text) from public, anon;
grant execute on function public.save_membership(uuid,date,date,text,int,timestamptz,text) to authenticated;
