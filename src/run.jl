function getcmd(fpsim::FlexpartSim)
    pn_path = pathnames_path(fpsim)
    `$(FLEXPART()) $pn_path`
end

"""
    $(TYPEDSIGNATURES)

Run Flexpart using the paths of `fpsim`.
"""
function run(fpsim::FlexpartSim{Deterministic}; log = false) 
    if log == false 
        _run_helper(fpsim; f = nothing)
    else
        logpath = joinpath(fpsim[:output], "output.log")
        open(logpath, "w") do logf
            run(fpsim) do io
                log_output(io, logf)
            end
        end
    end
end

run(f::Function, fpsim::FlexpartSim{Deterministic}) = _run_helper(fpsim; f = f)

run(fpsim::FlexpartSim{Ensemble}) = _run_helper(fpsim)

run() = FlexpartSim() do fpsim
    default_run(fpsim)
end

function _run_helper(fpsim::FlexpartSim{Deterministic}; f = nothing)
    # println("The following command will be run : $cmd")
    tempfpdir = FlexpartSim()
    tempfpdir[:options] = fpsim[:options]
    tempfpdir[:output] = fpsim[:output]
    tempfpdir[:input] = fpsim[:input]
    tempfpdir[:available] = fpsim[:available]

    save(tempfpdir)
    cmd = getcmd(tempfpdir)
    # println("Will run Flexpart with following pathnames: ")
    # println(tempfpdir.pathnames)
    if isnothing(f)
        Base.run(cmd)
    else
        pipe = Pipe()
        @async while true
            f(pipe)
        end

        Base.run(pipeline(cmd, stdout=pipe, stderr=pipe))
    end
    if !isempty(filter(x -> endswith(x, ".nc"), readdir(tempfpdir[:output])))
        nc_file = joinpath(tempfpdir[:output], filter(x -> endswith(x, ".nc"), readdir(tempfpdir[:output]))[1])
        _round_dims(nc_file)
        add_total_depo(nc_file)
    end
end

function _run_helper(fpsim::FlexpartSim{Ensemble})
    inputs = inputs_from_dir(fpsim[:input])
    members = [x.member for x in inputs] |> unique 
    sep_inputs = [filter(x -> x.member==i, inputs) for i in members]
    batch_size = 3

    for batch in Iterators.partition(sep_inputs, batch_size)
        @sync begin
            for realization in batch
                imember = realization[1].member
                tempfpdir = FlexpartSim()
                memb_out_path = joinpath(fpsim[:output], "member$(imember)")
                mkpath(memb_out_path)
                tempfpdir[:options] = fpsim[:options]
                tempfpdir[:output] = memb_out_path
                tempfpdir[:input] = fpsim[:input]
        
                det_inputs = convert.(DeterministicInput, realization)
                real_av = Available(det_inputs, tempfpdir[:available])
                save(real_av)
                saveabs(tempfpdir)
                
                log_path = joinpath(getpath(fpsim), "member$(imember).log")
                @async open(log_path, "w") do logf
                    run(tempfpdir) do io
                        log_output(io, logf)
                    end
                end 
            end
        end
    end
    create_ensemble_mean(fpsim)
end

function setup_pathnames(fpsim::FlexpartSim{Ensemble}; parentdir = tempdir())

    sep_inputs = _filter_members(fpsim)

    map(sep_inputs) do realization
        imember = realization[1].member
        realization_tmpdir = mktempdir(parentdir)
        pn = FpPathnames()
        pn.dirpath = realization_tmpdir

        memb_out_path = joinpath(fpsim[:output], "member$(imember)")
        mkpath(memb_out_path)
        pn.output = memb_out_path
        pn.options = fpsim[:options]
        pn.input = fpsim[:input]
        det_inputs = convert.(DeterministicInput, realization)

        real_av = Available(det_inputs, pn[:available])
        save(real_av)
        saverel(pn)

        realization_fpsim = FlexpartSim{Deterministic}(pn)
        imember, realization_fpsim
    end
end

function _filter_members(fpsim)
    inputs = _available_from_file(fpsim[:input], fpsim[:available])
    members = [x.member for x in inputs] |> unique 
    sep_inputs = [filter(x -> x.member==i, inputs) for i in members]
    return sep_inputs
end

function _round_dims(netcdf_file::AbstractString)
    # Check if the file path is valid
    if !ispath(netcdf_file)
        throw(ArgumentError("The provided file path '$netcdf_file' is not valid."))
    end
    ds = Dataset(netcdf_file, "r")
    # Extract dimensions
    longitudes = Float64.(round.(ds["longitude"][:], digits=4))
    latitudes = Float64.(round.(ds["latitude"][:], digits=4))
    close(ds)
    ds = Dataset(netcdf_file, "a")
    # Round the coordinates
    ds["longitude"][:] = longitudes
    ds["latitude"][:] = latitudes
    close(ds)
end

function add_total_depo(fp_output)
    ds = Dataset(fp_output, "a")
    if any(key -> occursin("WD_spec", key), keys(ds)) && any(key -> occursin("DD_spec", key), keys(ds))
        wet_depo_keys = filter(v -> startswith(v, "WD_spec"), keys(ds))
        dry_depo_keys = filter(v -> startswith(v, "DD_spec"), keys(ds))
        for wet_key in wet_depo_keys
            spec_num = wet_key[8:end]
            dry_key = "DD_spec$spec_num"
            total_key = "TD_spec$spec_num"
            if !haskey(ds, total_key)
                wet_depo = ds[wet_key]
                dry_depo = ds[dry_key]
                total_depo = Array(wet_depo) + Array(dry_depo)
                defVar(ds, total_key, total_depo, dimnames(wet_depo), attrib=["units" => wet_depo.attrib["units"]])
            else
                nothing
            end
        end
    else
        nothing
    end
    close(ds)
end

function create_ensemble_mean(fpsim::FlexpartSim{Ensemble})
    # List ensemble members netcdf file paths
    output_dir = fpsim[:output]
    filepaths = []
    for i in range(1, count(f -> isdir(f), joinpath.(output_dir, readdir(output_dir))))
        member_dir = joinpath(output_dir, "member$i")
        push!(filepaths, joinpath(member_dir, filter(x -> endswith(x, ".nc"), readdir(member_dir))[1]))
    end
    # Create and initialize ensemble netcdf file
    file_mean = joinpath(output_dir, "ensemble_mean.nc")
    ds_mean = Dataset(file_mean, "c")
    ds = Dataset(filepaths[1])
    ds_mean["time"] = ds["time"]
    ds_mean["longitude"] = ds["longitude"]
    ds_mean["latitude"] = ds["latitude"]
    ds_mean["height"] = ds["height"]
    ds_mean["spec001_mr"] = ds["spec001_mr"]
    ds_mean["TD_spec001"] = ds["TD_spec001"]
    mean_conc = Array(ds["spec001_mr"])
    mean_depo = Array(ds["TD_spec001"])
    close(ds)
    # Sum the data across all ensemble members
    for file in filepaths[2:end]
        ds = Dataset(file)
        mean_conc .+= Array(ds["spec001_mr"])
        mean_depo .+= Array(ds["TD_spec001"])
        close(ds)
    end
    # Divide by number of members to get the mean
    mean_conc ./= length(filepaths)
    mean_depo ./= length(filepaths)
    # Write the results to ensemble netcdf file
    ds_mean["spec001_mr"][:] = mean_conc
    ds_mean["TD_spec001"][:] = mean_depo
    close(ds_mean)
end

function log_output(io::IO, fileio::IO)
    line = readline(io, keep=true)
    Base.write(fileio, line)
    flush(fileio)
end

function default_run(fpsim::FlexpartSim{Deterministic})
    fpsim[:input] = abspath(FP_TESTS_DETER_INPUT)
    dummy_run(fpsim)
end

function dummy_run(fpsim::FlexpartSim{Deterministic})
    avs = Available(fpsim)
    options = FlexpartOption(fpsim)
    set_cmd_dates!(options, avs)
    set_release_at_start!(options, avs, Dates.Minute(30))
    input_area = grib_area(avs[1])
    lon = input_area[2] + (input_area[4] - input_area[2]) / 2
    lat = input_area[3] + (input_area[1] - input_area[3]) / 2
    set_point_release!(options, lon, lat)
    gridres, _ = Flexpart.grib_resolution(avs[1])
    outgrid = Flexpart.area2outgrid(fpsim, gridres)
    merge!(options["OUTGRID"][:OUTGRID], outgrid)
    options["COMMAND"][:COMMAND][1][:IOUT] = 9
    Flexpart.save(avs)
    Flexpart.save(options)
    Flexpart.run(fpsim)
end
